#!/usr/bin/env bash
#
# Builds the Docker image once (which also pre-compiles the app + tests and
# warms the Maven plugin cache — see Dockerfile), then runs each JUnit 5
# test class in its own brand-new, ephemeral container (docker run --rm),
# IN PARALLEL. Each container calls the surefire:test goal directly against
# the classes already baked into the image, so no container ever runs
# `mvn compile` itself. Each invocation of `docker run` still starts a
# fresh container from the built image, so every test class gets a fully
# reset container (clean filesystem, clean JVM, no state left over from
# any other test) — they just all run at the same time instead of one
# after another.
#
set -uo pipefail

# Always run relative to this script's location (the project root),
# regardless of the working directory this was invoked from (e.g. Maven's
# exec-maven-plugin, or CI).
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

IMAGE_NAME="simple-app-tests"

echo "==> Building Docker image (${IMAGE_NAME})..."
docker build -t "${IMAGE_NAME}" .

echo "==> Discovering test classes..."
# Find all *Test.java files under src/test/java and turn the path into a
# fully-qualified class name, e.g. com.example.WebServerTest
TEST_CLASSES=$(find src/test/java -name "*Test.java" | \
  sed -e 's#^src/test/java/##' -e 's#\.java$##' -e 's#/#.#g')

if [ -z "${TEST_CLASSES}" ]; then
  echo "No test classes found."
  exit 1
fi

LOG_DIR="$(mktemp -d)"
trap 'rm -rf "${LOG_DIR}"' EXIT

declare -A PIDS

echo ""
echo "==> Launching one fresh, isolated container per test class, in parallel..."

for CLASS in ${TEST_CLASSES}; do
  echo "==> Starting container for: ${CLASS}"
  (
    # `surefire:test` is called directly (a single plugin goal), NOT the
    # "test" lifecycle phase. That means it does not trigger compile /
    # test-compile — it just runs the class files that were already built
    # into the image at `docker build` time (see Dockerfile). -o keeps it
    # offline since the image already has everything cached.
    docker run --rm "${IMAGE_NAME}" \
      mvn -q -B -o surefire:test -Dtest="${CLASS}" \
      -Dskip.local.tests=false -Dexec.skip=true \
      > "${LOG_DIR}/${CLASS}.log" 2>&1
    echo $? > "${LOG_DIR}/${CLASS}.exit"
  ) &
  PIDS["${CLASS}"]=$!
done

# Wait for every container to finish before reporting results.
for CLASS in "${!PIDS[@]}"; do
  wait "${PIDS[${CLASS}]}"
done

FAILED=0

echo ""
echo "==> Results"
echo "----------------------------------------"

for CLASS in ${TEST_CLASSES}; do
  EXIT_CODE="$(cat "${LOG_DIR}/${CLASS}.exit" 2>/dev/null || echo 1)"

  echo ""
  echo "----- ${CLASS} -----"
  cat "${LOG_DIR}/${CLASS}.log" 2>/dev/null

  if [ "${EXIT_CODE}" -eq 0 ]; then
    echo "==> ${CLASS} PASSED"
  else
    echo "==> ${CLASS} FAILED"
    FAILED=1
  fi
done

echo ""
if [ "${FAILED}" -eq 0 ]; then
  echo "All tests passed (each in its own freshly reset container, run in parallel)."
else
  echo "Some tests failed."
  exit 1
fi
