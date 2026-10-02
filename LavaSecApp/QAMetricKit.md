# QA MetricKit

Compiled only with the internal QA compilation condition; registration also requires the QA bundle ID
`com.lavasec.dev.qa`. Ordinary Debug and production Release contain no collector
or MetricKit registration. The shared app delegate starts it for both native and
full React Native QA apps. Extensions do not register.

Metric and diagnostic payloads are retained verbatim as local JSON under the QA
app's `Library/Application Support/QAMetricKit/`. No automatic upload or inclusion
in feedback bundles. Files are protected until first unlock and excluded from
backup. Retention: 14 days since receipt, at most 64 reports / 20 MiB, with a 5 MiB
per-report limit. Cleanup runs at startup and receipt. Duplicate payloads share a
SHA-256 filename. Storage failures emit a reason-only QA log event.

Pull with the phone connected (replace DEVICE with its identifier):

```sh
xcrun devicectl device copy from --device DEVICE --domain-type appDataContainer \
  --domain-identifier com.lavasec.dev.qa \
  --source 'Library/Application Support/QAMetricKit' --destination ./qa-metrickit
```

Apple delivers metrics periodically, generally daily; absence immediately after
installation is expected. Payloads identify their reporting interval and app
version. Reports can span usage predating a callback and must not be attributed
solely to the currently installed build. These are app reports, not a guaranteed
breakdown of the packet-tunnel extension or a direct battery percentage. Retain
the existing tunnel NRG counters and use Instruments for controlled energy work.

Reference: https://developer.apple.com/documentation/metrickit/mxmetricmanager
