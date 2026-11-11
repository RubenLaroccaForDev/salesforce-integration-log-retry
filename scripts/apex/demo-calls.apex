// Two demo calls: the first succeeds, the second returns 503 and is retried until it ends as KO.
IntegrationService.send(null, 'https://postman-echo.com/post', 'POST', '{"orderId": 42, "customer": "ACME"}');
IntegrationService.send(null, 'https://postman-echo.com/status/503', 'GET', null);
