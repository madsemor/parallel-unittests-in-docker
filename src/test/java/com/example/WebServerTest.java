package com.example;

import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;

import java.io.BufferedReader;
import java.io.IOException;
import java.io.InputStreamReader;
import java.net.HttpURLConnection;
import java.net.URL;
import java.nio.charset.StandardCharsets;

import static org.junit.jupiter.api.Assertions.assertEquals;

/**
 * These tests start a real instance of {@link WebServer} on an ephemeral
 * port and make actual HTTP requests against it, rather than calling any
 * method directly. This exercises the full request/response path.
 */
class WebServerTest {

    private static WebServer server;
    private static int port;

    @BeforeAll
    static void startServer() throws IOException {
        // port 0 -> OS assigns a free port, so tests never clash with
        // anything else already listening.
        server = new WebServer(7000);
        server.start();
        port = 7000;//server.getPort();
    }

    @AfterAll
    static void stopServer() {
        server.stop();
    }

    @Test
    void helloEndpointReturnsGreeting() throws IOException {
        HttpResponse response = get("/hello");
        assertEquals(200, response.statusCode);
        assertEquals("Hello, World!", response.body);
    }

    @Test
    void addEndpointReturnsSum() throws IOException {
        HttpResponse response = get("/add?a=2&b=3");
        assertEquals(200, response.statusCode);
        assertEquals("5", response.body);
    }

    private HttpResponse get(String path) throws IOException {
        URL url = new URL("http://localhost:" + port + path);
        HttpURLConnection conn = (HttpURLConnection) url.openConnection();
        conn.setRequestMethod("GET");
        int statusCode = conn.getResponseCode();
        try (BufferedReader reader = new BufferedReader(new InputStreamReader(
                statusCode < 400 ? conn.getInputStream() : conn.getErrorStream(),
                StandardCharsets.UTF_8))) {
            StringBuilder sb = new StringBuilder();
            String line;
            while ((line = reader.readLine()) != null) {
                sb.append(line);
            }
            return new HttpResponse(statusCode, sb.toString());
        } finally {
            conn.disconnect();
        }
    }

    private static class HttpResponse {
        final int statusCode;
        final String body;

        HttpResponse(int statusCode, String body) {
            this.statusCode = statusCode;
            this.body = body;
        }
    }
}
