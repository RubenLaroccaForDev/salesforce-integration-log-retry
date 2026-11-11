@IsTest
private class IntegrationServiceTest {

    private static final String ENDPOINT = 'https://postman-echo.com/post';

    /** Returns the given status and echoes the request body; a null status simulates a timeout. */
    private class EchoMock implements HttpCalloutMock {
        private final Integer status;
        EchoMock(Integer status) { this.status = status; }

        public HttpResponse respond(HttpRequest req) {
            if (status == null) {
                throw new CalloutException('Read timed out');
            }
            HttpResponse res = new HttpResponse();
            res.setStatusCode(status);
            res.setBody('{"json":' + req.getBody() + ',"correlation":"' + req.getHeader('X-Correlation-Id') + '"}');
            return res;
        }
    }

    private static Integration_Log__c runAttempt(Integer mockStatus, Integer attempt) {
        Test.setMock(HttpCalloutMock.class, new EchoMock(mockStatus));
        IntegrationService.Request r = new IntegrationService.Request();
        r.endpoint = ENDPOINT;
        r.method = 'POST';
        r.body = '{"orderId":42}';
        r.attempt = attempt;

        Test.startTest();
        System.enqueueJob(new IntegrationService(r));
        Test.stopTest();

        return [
            SELECT Outcome__c, Status_Code__c, Attempt__c, Error_Message__c,
                   Request_Body__c, Response_Body__c, Correlation_Id__c, Method__c
            FROM Integration_Log__c
        ];
    }

    @IsTest
    static void successIsLoggedAsOk() {
        Integration_Log__c log = runAttempt(200, 1);

        Assert.areEqual('OK', log.Outcome__c);
        Assert.areEqual(200, log.Status_Code__c);
        Assert.areEqual(1, log.Attempt__c);
        Assert.areEqual('POST', log.Method__c);
        Assert.areEqual('{"orderId":42}', log.Request_Body__c);
        Assert.isTrue(log.Response_Body__c.contains('"orderId":42'), 'response body should be logged');
        Assert.isTrue(log.Response_Body__c.contains(log.Correlation_Id__c), 'correlation id should be sent as header');
    }

    @IsTest
    static void serverErrorIsRetried() {
        Integration_Log__c log = runAttempt(503, 1);

        Assert.areEqual('RETRY', log.Outcome__c);
        Assert.areEqual(503, log.Status_Code__c);
    }

    @IsTest
    static void serverErrorOnLastAttemptIsKo() {
        Integration_Log__c log = runAttempt(503, IntegrationService.MAX_ATTEMPTS);

        Assert.areEqual('KO', log.Outcome__c);
        Assert.areEqual(IntegrationService.MAX_ATTEMPTS, log.Attempt__c);
    }

    @IsTest
    static void clientErrorIsNotRetried() {
        Integration_Log__c log = runAttempt(400, 1);

        Assert.areEqual('KO', log.Outcome__c);
        Assert.areEqual(400, log.Status_Code__c);
    }

    @IsTest
    static void timeoutIsLoggedAndRetried() {
        Integration_Log__c log = runAttempt(null, 1);

        Assert.areEqual('RETRY', log.Outcome__c);
        Assert.isNull(log.Status_Code__c);
        Assert.areEqual('Read timed out', log.Error_Message__c);
    }

    @IsTest
    static void outcomeRules() {
        Assert.areEqual('OK', IntegrationService.outcome(201, 1));
        Assert.areEqual('RETRY', IntegrationService.outcome(429, 1));
        Assert.areEqual('KO', IntegrationService.outcome(404, 1));
        Assert.areEqual('KO', IntegrationService.outcome(null, IntegrationService.MAX_ATTEMPTS));
    }

    @IsTest
    static void sendRejectsInvalidInput() {
        try {
            IntegrationService.send(null, ' ', 'POST', null);
            Assert.fail('blank endpoint should be rejected');
        } catch (IllegalArgumentException e) {
            Assert.isTrue(e.getMessage().contains('Endpoint'));
        }
        try {
            IntegrationService.send(null, ENDPOINT, 'TRACE', null);
            Assert.fail('unsupported method should be rejected');
        } catch (IllegalArgumentException e) {
            Assert.isTrue(e.getMessage().contains('TRACE'));
        }
    }

    @IsTest
    static void flowActionQueuesOneCallPerInput() {
        Test.setMock(HttpCalloutMock.class, new EchoMock(200));
        List<IntegrationInvocable.Input> inputs = new List<IntegrationInvocable.Input>();
        for (Integer i = 0; i < 2; i++) {
            IntegrationInvocable.Input input = new IntegrationInvocable.Input();
            input.endpoint = ENDPOINT;
            input.method = 'post';
            input.body = '{"n":' + i + '}';
            inputs.add(input);
        }

        Test.startTest();
        IntegrationInvocable.send(inputs);
        Test.stopTest();

        List<Integration_Log__c> logs = [SELECT Outcome__c, Method__c FROM Integration_Log__c];
        Assert.areEqual(2, logs.size());
        for (Integration_Log__c log : logs) {
            Assert.areEqual('OK', log.Outcome__c);
            Assert.areEqual('POST', log.Method__c, 'method should be normalised to upper case');
        }
    }
}
