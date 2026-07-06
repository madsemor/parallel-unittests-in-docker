# Java 8 + Maven image
FROM maven:3.9-eclipse-temurin-8

WORKDIR /usr/src/app

# Copy only the pom first so Maven can cache dependencies in a layer
COPY pom.xml .
RUN mvn -q -B dependency:go-offline

# Now copy the rest of the source
COPY src ./src

# Default command: run the full test suite.
# Override with `-Dtest=ClassName` (via `mvn test -Dtest=...`) to run a single test class,
# see run-tests.sh for how each test class gets its own fresh, ephemeral container.
CMD ["mvn", "-q", "-B", "test"]
