# simple-app

A minimal Java 8 / Maven application that starts a simple HTTP web server
(using the JDK's built-in `com.sun.net.httpserver.HttpServer` — no external
web framework needed). It has two JUnit 5 tests that start a real instance
of the server and make actual HTTP requests against it. Everything is built
and tested entirely inside Docker, and the container is reset before every
test runs.

## Endpoints

- `GET /hello` -> `Hello, World!`
- `GET /add?a=2&b=3` -> `5`

## Project layout

```
simple-app/
├── Dockerfile
├── pom.xml
├── run-tests.sh
├── src/
│   ├── main/java/com/example/App.java        (starts WebServer on port 8080)
│   ├── main/java/com/example/WebServer.java   (the HTTP server + handlers)
│   └── test/java/com/example/WebServerTest.java
```

## How the tests work

`WebServerTest` starts a real `WebServer` on an OS-assigned ephemeral port
(`port 0`) in a `@BeforeAll`, then each `@Test` method opens an actual
`HttpURLConnection` to `http://localhost:<port>/...` and asserts on the
response status code and body — a genuine end-to-end HTTP test rather than
calling any method directly. `@AfterAll` stops the server afterward.

## Running tests via Maven (`mvn package`)

Local JUnit execution is disabled in `pom.xml` (`maven-surefire-plugin` has
`skipTests=true`). Instead, `exec-maven-plugin` is bound to Maven's `test`
phase and invokes `run-tests.sh`, which builds the Docker image and runs the
tests inside containers. Since `package` depends on `test`, this happens
automatically:

```bash
mvn package
```

- Requires Docker to be installed and running on the machine invoking Maven.
- If any test fails inside its container, `run-tests.sh` exits non-zero,
  which makes `exec-maven-plugin` fail the build — so `mvn package` fails
  too, exactly as if the tests had failed locally.
- `mvn test` alone also triggers the same Docker-based test run, since it's
  bound to the `test` phase.
- To build the jar without running any tests: `mvn package -DskipTests` —
  note this is a Maven property, but since the Docker run is driven by
  `exec-maven-plugin` rather than surefire, it's cleanest to instead skip
  the exec execution directly: `mvn package -Dexec.skip=true`.

## How "reset before each test" works

`run-tests.sh` builds the Docker image once, then loops over every
`*Test.java` class it finds and runs it with:

```bash
docker run --rm simple-app-tests mvn -q -B test -Dtest=<ClassName>
```

Each `docker run` call spins up a **brand-new container** from the image
and `--rm` deletes it as soon as it finishes. That means:

- No leftover files, processes, or JVM state from a previous test.
- Every test class starts from the exact same clean image state.
- A crashed or hung test can't affect the next one — it's a different
  container entirely.

## Usage

Requires Docker installed locally.

```bash
cd simple-app
./run-tests.sh
```

Example output:

```
==> Building Docker image (simple-app-tests)...
==> Discovering test classes...
==> Resetting container and running: com.example.WebServerTest
==> com.example.WebServerTest PASSED

All tests passed (each in its own freshly reset container).
```

### Running everything in one go instead

If you don't need per-test isolation and just want the whole suite in one
container:

```bash
docker build -t simple-app-tests .
docker run --rm simple-app-tests
```

(This uses the Dockerfile's default `CMD`, which runs `mvn test` for the
full suite.)

### Running the server itself (not just the tests)

```bash
docker build -t simple-app-tests .
docker run --rm -p 8080:8080 simple-app-tests \
  mvn -q -B compile exec:java -Dexec.mainClass=com.example.App
```

Then, from your host:

```bash
curl http://localhost:8080/hello       # -> Hello, World!
curl "http://localhost:8080/add?a=2&b=3"  # -> 5
```

### Building the jar

```bash
docker run --rm -v "$(pwd)/target:/usr/src/app/target" simple-app-tests mvn -q -B package -DskipTests
```
