package com.example;

public class App {
    public static void main(String[] args) throws Exception {
        int port = 8080;
        WebServer server = new WebServer(port);
        server.start();
        System.out.println("Server started on port " + server.getPort());
    }
}
