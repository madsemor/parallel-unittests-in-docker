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

echo "==> Discovering test targets..."
# Parse each Java test source file to discover test methods and, for
# parameterized tests, derive each invocation as its own target.
TEST_TARGETS=()

if command -v python3 >/dev/null 2>&1; then
  PYTHON_BIN="python3"
elif command -v python >/dev/null 2>&1; then
  PYTHON_BIN="python"
else
  echo "Python is required to discover parameterized test targets."
  exit 1
fi

while IFS= read -r TARGET; do
  TEST_TARGETS+=("${TARGET}")
done < <("${PYTHON_BIN}" "${PWD}/discover_test_targets.py" "${PWD}" --filter-class WebServerTest)

if [ ${#TEST_TARGETS[@]} -eq 0 ]; then
  echo "No test targets found."
  exit 1
fi

LOG_DIR="$(mktemp -d "${PWD}/.tmp-test-logs.XXXXXX")"
trap 'rm -rf "${LOG_DIR}"' EXIT

RUN_TARGETS=()
PIDS=()
MAX_CONCURRENT=4

echo ""
echo "==> Launching fresh, isolated containers with a concurrency limit of ${MAX_CONCURRENT}..."

for TARGET in "${TEST_TARGETS[@]}"; do
  RUN_TARGETS+=("${TARGET}")
  echo "==> Starting container for: ${TARGET}"
  (
    # `surefire:test` is called directly (a single plugin goal), NOT the
    # "test" lifecycle phase. That means it does not trigger compile /
    # test-compile — it just runs the class files that were already built
    # into the image at `docker build` time (see Dockerfile). -o keeps it
    # offline since the image already has everything cached.
    docker run --rm "${IMAGE_NAME}" \
      mvn -q -B -o surefire:test -Dtest="${TARGET}" \
      -Dskip.local.tests=false -Dexec.skip=true \
      > "${LOG_DIR}/${TARGET}.log" 2>&1
    echo $? > "${LOG_DIR}/${TARGET}.exit"
  ) &
  PIDS+=("$!")

  if [ ${#PIDS[@]} -ge ${MAX_CONCURRENT} ]; then
    WAIT_PID="${PIDS[0]}"
    wait "${WAIT_PID}" 2>/dev/null || true
    PIDS=(${PIDS[@]:1})
  fi
done

# Wait for any remaining spawned containers to finish before reporting results.
for PID in "${PIDS[@]}"; do
  wait "${PID}" 2>/dev/null || true
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
