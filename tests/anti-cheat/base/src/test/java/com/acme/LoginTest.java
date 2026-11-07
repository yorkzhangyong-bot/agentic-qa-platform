package com.acme;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.time.Duration;
import org.junit.jupiter.api.Test;
import org.openqa.selenium.By;
import org.openqa.selenium.support.ui.ExpectedConditions;
import org.openqa.selenium.support.ui.WebDriverWait;

class LoginTest extends BaseTest {

    @Test
    void logsIn() {
        driver.get(baseUrl + "/login");
        driver.findElement(By.id("email")).sendKeys("user@example.com");
        driver.findElement(By.id("submit")).click();
        new WebDriverWait(driver, Duration.ofSeconds(10))
            .until(ExpectedConditions.visibilityOfElementLocated(By.id("welcome")));
        assertEquals("Welcome back", driver.findElement(By.id("welcome")).getText());
    }
}
