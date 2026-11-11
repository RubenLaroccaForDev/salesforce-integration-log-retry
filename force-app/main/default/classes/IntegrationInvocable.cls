/**
 * Flow action: "Send to External API". Lets admins call any REST endpoint from a Flow
 * and get the same logging and retry as Apex callers.
 */
public with sharing class IntegrationInvocable {

    public class Input {
        @InvocableVariable(label='Record Id' description='Record the call refers to (optional)')
        public Id recordId;
        @InvocableVariable(label='Endpoint' description='Full URL or callout:Named_Credential/path' required=true)
        public String endpoint;
        @InvocableVariable(label='HTTP Method' description='GET, POST, PUT, PATCH or DELETE' required=true)
        public String method;
        @InvocableVariable(label='JSON Body')
        public String body;
    }

    // shortcut: one Queueable per input, so a single transaction handles at most 50 records
    // (Apex limit on enqueued jobs); batch the inputs into one job if bulk Flows need more.
    @InvocableMethod(label='Send to External API' description='Queues a REST callout with logging and automatic retry')
    public static void send(List<Input> inputs) {
        for (Input i : inputs) {
            IntegrationService.send(i.recordId, i.endpoint, i.method, i.body);
        }
    }
}
