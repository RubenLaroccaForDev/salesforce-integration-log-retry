/**
 * Sends a REST callout asynchronously, logs every attempt to Integration_Log__c
 * and retries transient failures (timeouts, HTTP 429 and 5xx) with a growing delay.
 * Client errors (other 4xx) are not retried: sending the same request again would fail again.
 */
public with sharing class IntegrationService implements Queueable, Database.AllowsCallouts {

    @TestVisible private static final Integer MAX_ATTEMPTS = 3;
    private static final Set<String> METHODS = new Set<String>{ 'GET', 'POST', 'PUT', 'PATCH', 'DELETE' };
    private static final Integer MAX_BODY = 131072;

    public class Request {
        public Id recordId;
        public String endpoint;
        public String method;
        public String body;
        public String correlationId;
        public Integer attempt = 1;
    }

    private final Request req;

    public IntegrationService(Request req) {
        this.req = req;
        if (String.isBlank(req.correlationId)) {
            req.correlationId = EncodingUtil.convertToHex(Crypto.generateAesKey(128));
        }
    }

    /** Entry point: validates the input and queues the first attempt. Returns the async job id. */
    public static Id send(Id recordId, String endpoint, String method, String body) {
        if (String.isBlank(endpoint)) {
            throw new IllegalArgumentException('Endpoint is required');
        }
        String verb = String.isBlank(method) ? '' : method.toUpperCase();
        if (!METHODS.contains(verb)) {
            throw new IllegalArgumentException('Unsupported HTTP method: ' + method);
        }
        Request r = new Request();
        r.recordId = recordId;
        r.endpoint = endpoint;
        r.method = verb;
        r.body = body;
        return System.enqueueJob(new IntegrationService(r));
    }

    public void execute(QueueableContext ctx) {
        Integration_Log__c log = new Integration_Log__c(
            Record_Id__c = req.recordId,
            Correlation_Id__c = req.correlationId,
            Endpoint__c = req.endpoint.left(255),
            Method__c = req.method,
            Request_Body__c = req.body == null ? null : req.body.left(MAX_BODY),
            Attempt__c = req.attempt
        );

        Integer status;
        try {
            HttpRequest http = new HttpRequest();
            http.setEndpoint(req.endpoint);
            http.setMethod(req.method);
            http.setTimeout(20000);
            http.setHeader('Content-Type', 'application/json');
            http.setHeader('X-Correlation-Id', req.correlationId);
            if (String.isNotBlank(req.body)) {
                http.setBody(req.body);
            }
            HttpResponse res = new Http().send(http);
            status = res.getStatusCode();
            log.Status_Code__c = status;
            log.Response_Body__c = res.getBody() == null ? null : res.getBody().left(MAX_BODY);
        } catch (CalloutException e) {
            log.Error_Message__c = e.getMessage().left(255);
        }

        log.Outcome__c = outcome(status, req.attempt);
        // Logs must be written even when the running user cannot create them.
        Database.insert(log, AccessLevel.SYSTEM_MODE);

        if (log.Outcome__c == 'RETRY') {
            scheduleRetry();
        }
    }

    /** OK for 2xx; RETRY for transient failures while attempts are left; KO otherwise. */
    @TestVisible
    private static String outcome(Integer status, Integer attempt) {
        if (status != null && status >= 200 && status < 300) {
            return 'OK';
        }
        Boolean transientFailure = status == null || status == 429 || status >= 500;
        return transientFailure && attempt < MAX_ATTEMPTS ? 'RETRY' : 'KO';
    }

    private void scheduleRetry() {
        Request next = new Request();
        next.recordId = req.recordId;
        next.endpoint = req.endpoint;
        next.method = req.method;
        next.body = req.body;
        next.correlationId = req.correlationId;
        next.attempt = req.attempt + 1;
        // Back off: 1 minute before the 2nd attempt, 2 minutes before the 3rd.
        Integer delayMinutes = req.attempt;
        // shortcut: Apex tests cannot chain Queueables, so the retry itself is not enqueued under test;
        // the decision to retry is covered through the RETRY outcome.
        if (!Test.isRunningTest()) {
            System.enqueueJob(new IntegrationService(next), delayMinutes);
        }
    }
}
