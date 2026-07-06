package com.example;

import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;

class CalculatorTest {

    private Calculator calculator;

    @BeforeEach
    void setUp() {
        // Fresh instance for every test method (in-JVM reset).
        calculator = new Calculator();
    }

    @Test
    void addsTwoNumbersCorrectly() {
        assertEquals(5, calculator.add(2, 3));
    }

    @Test
    void divideByZeroThrowsException() {
        assertThrows(IllegalArgumentException.class, () -> calculator.divide(10, 0));
    }
}
