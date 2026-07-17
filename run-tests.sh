#!/usr/bin/env bash
#
# Builds the Docker image once (which also pre-compiles the app + tests and
# warms the Maven plugin cache — see Dockerfile), then runs each JUnit 5
# test target (a whole test class, or an individual parameterized invocation)
# in its own brand-new, ephemeral container (docker run --rm), IN PARALLEL.
# Each container calls the surefire:test goal directly against the classes
# already baked into the image, so no container ever runs `mvn compile`
# itself. Each invocation of `docker run` still starts a fresh container from
# the built image, so every test target gets a fully reset container (clean
# filesystem, clean JVM, no state left over from any other test) — they just
# all run at the same time instead of one after another.
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
# fully-qualified class name, e.g. com.example.WebServerTest.
# Using an array keeps each discovered class name as a separate entry so we
# can start every test class in its own background job.
mapfile -t TEST_CLASSES < <(find src/test/java -name "*Test.java" | \
  sed -e 's#^src/test/java/##' -e 's#\.java$##' -e 's#/#.#g')

if [ ${#TEST_CLASSES[@]} -eq 0 ]; then
  echo "No test classes found."
  exit 1
fi

LOG_DIR="$(mktemp -d)"
trap 'rm -rf "${LOG_DIR}"' EXIT

declare -A PIDS
declare -a RUN_TARGETS=()
MAX_PARALLEL=4
ACTIVE=0

echo ""
echo "==> Launching up to ${MAX_PARALLEL} fresh, isolated containers at a time..."

for CLASS in "${TEST_CLASSES[@]}"; do
  TARGETS=("${CLASS}")

  # For the WebServerTest parameterized add endpoint test, run each parameter
  # set as its own isolated container so the cases execute independently.
  if [ "${CLASS}" = "com.example.WebServerTest" ]; then
    TARGETS=(
      "com.example.WebServerTest#helloEndpointReturnsGreeting"
      "com.example.WebServerTest#addEndpointReturnsSum[1]"
      "com.example.WebServerTest#addEndpointReturnsSum[2]"
      "com.example.WebServerTest#addEndpointReturnsSum[3]"
    )
  fi

  for TARGET in "${TARGETS[@]}"; do
    RUN_TARGETS+=("${TARGET}")
    echo "==> Starting container for: ${TARGET}"
    (
      # `surefire:test` is called directly (a single plugin goal), NOT the
      # "test" lifecycle phase. That means it does not trigger compile /
      # test-compile — it just runs the class files that were already built
      # into the image at `docker build` time (see Dockerfile). -o keeps it
      # offline since the image already has everything cached.
      docker run --rm  "${IMAGE_NAME}" \
        mvn -q -B -o surefire:test -Dtest="${TARGET}" \
        -Dskip.local.tests=false -Dexec.skip=true \
        > "${LOG_DIR}/${TARGET}.log" 2>&1
      echo $? > "${LOG_DIR}/${TARGET}.exit"
    ) &
    PIDS["${TARGET}"]=$!
    ACTIVE=$((ACTIVE + 1))

    if [ "${ACTIVE}" -ge "${MAX_PARALLEL}" ]; then
      TARGET_TO_WAIT="${TARGET}"
      wait "${PIDS[${TARGET_TO_WAIT}]}"
      ACTIVE=$((ACTIVE - 1))
    fi
  done
done

# Wait for any remaining containers to finish before reporting results.
for TARGET in "${RUN_TARGETS[@]}"; do
  if wait "${PIDS[${TARGET}]}" 2>/dev/null; then
    :
  fi
done

FAILED=0

echo ""
echo "==> Results"
echo "----------------------------------------"

for TARGET in "${RUN_TARGETS[@]}"; do
  EXIT_CODE="$(cat "${LOG_DIR}/${TARGET}.exit" 2>/dev/null || echo 1)"

  echo ""
  echo "----- ${TARGET} -----"
  cat "${LOG_DIR}/${TARGET}.log" 2>/dev/null

  if [ "${EXIT_CODE}" -eq 0 ]; then
    echo "==> ${TARGET} PASSED"
  else
    echo "==> ${TARGET} FAILED"
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
