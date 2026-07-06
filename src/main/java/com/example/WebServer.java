package com.example;

import com.sun.net.httpserver.HttpExchange;
import com.sun.net.httpserver.HttpHandler;
import com.sun.net.httpserver.HttpServer;

import java.io.IOException;
import java.io.OutputStream;
import java.net.InetSocketAddress;
import java.nio.charset.StandardCharsets;
import java.util.HashMap;
import java.util.Map;
import java.util.concurrent.Executors;

/**
 * A minimal HTTP web server built on the JDK's built-in
 * {@code com.sun.net.httpserver.HttpServer} — no external dependencies
 * needed, works on plain Java 8.
 *
 * Exposes:
 *   GET /hello         -> "Hello, World!"
 *   GET /add?a=1&b=2   -> "3"
 */
public class WebServer {

    private final HttpServer server;

    /**
     * @param port the port to bind to. Use 0 to let the OS pick a free
     *             ephemeral port (handy for tests, avoids port clashes).
     */
    public WebServer(int port) throws IOException {
        this.server = HttpServer.create(new InetSocketAddress(port), 0);
        server.createContext("/hello", new HelloHandler());
        server.createContext("/add", new AddHandler());
        server.setExecutor(Executors.newFixedThreadPool(4));
    }

    public void start() {
        server.start();
    }

    public void stop() {
        server.stop(0);
    }

    /** Returns the actual port the server is bound to. */
    public int getPort() {
        return server.getAddress().getPort();
    }

    private static class HelloHandler implements HttpHandler {
        @Override
        public void handle(HttpExchange exchange) throws IOException {
            sendResponse(exchange, 200, "Hello, World!");
        }
    }

    private static class AddHandler implements HttpHandler {
        @Override
        public void handle(HttpExchange exchange) throws IOException {
            Map<String, String> params = parseQuery(exchange.getRequestURI().getQuery());
            try {
                int a = Integer.parseInt(params.getOrDefault("a", "0"));
                int b = Integer.parseInt(params.getOrDefault("b", "0"));
                sendResponse(exchange, 200, String.valueOf(a + b));
            } catch (NumberFormatException e) {
                sendResponse(exchange, 400, "Invalid input: 'a' and 'b' must be integers");
            }
        }
    }

    private static Map<String, String> parseQuery(String query) {
        Map<String, String> result = new HashMap<>();
        if (query == null || query.isEmpty()) {
            return result;
        }
        for (String pair : query.split("&")) {
            String[] kv = pair.split("=", 2);
            if (kv.length == 2) {
                result.put(kv[0], kv[1]);
            }
        }
        return result;
    }

    private static void sendResponse(HttpExchange exchange, int statusCode, String body) throws IOException {
        byte[] bytes = body.getBytes(StandardCharsets.UTF_8);
        exchange.sendResponseHeaders(statusCode, bytes.length);
        try (OutputStream os = exchange.getResponseBody()) {
            os.write(bytes);
        }
    }
}
