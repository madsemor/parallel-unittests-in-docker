# Java 8 + Maven image
FROM maven:3.9-eclipse-temurin-8

WORKDIR /usr/src/app

# Copy only the pom first so Maven can cache dependencies in a layer
COPY pom.xml .
RUN mvn -q -B dependency:go-offline

# Now copy the rest of the source
COPY src ./src

# Pre-build everything at IMAGE BUILD time, not container start time:
#   - compiles main + test sources (target/classes, target/test-classes)
#   - runs the tests once here, which also warms ~/.m2 with every plugin
#     needed to execute tests (surefire, junit-platform, etc.)
# -Dskip.local.tests=false forces tests to actually run here (they're
# skipped by default; see pom.xml). -Dexec.skip=true prevents the
# exec-maven-plugin's docker-based test execution (bound to the "test"
# phase, see pom.xml) from firing recursively during this build step.
RUN mvn -q -B -Dskip.local.tests=false -Dexec.skip=true test

# Default command: re-run the ALREADY-COMPILED tests by invoking the
# surefire plugin's goal directly. Calling a plugin goal this way (instead
# of the "test" phase) does NOT trigger the compile/test-compile phases,
# so no container ever needs to run `mvn compile` again — it just executes
# the class files that were already baked into this image above. -o keeps
# it fully offline since every dependency/plugin was cached during build.
CMD ["mvn", "-q", "-B", "-o", "surefire:test", "-Dskip.local.tests=false", "-Dexec.skip=true"]
