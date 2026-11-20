# ![Logo](/media/Logo.png) &nbsp; DMO Segment Sync Framework

## Introduction

The **DMO Segment Sync** framework is a set of Apex classes which periodically keeps
the list of **Data360** segments of a data space aligned with the values of a field in a
**Data360** Data Model Object (DMO).

A typical use case is a DMO containing segment assignments computed outside of **Data360**
(e.g. by a scoring tool or an external system), where each record carries the name of the
segment its individual belongs to. Whenever a new segment name value appears in the DMO,
the framework automatically creates a matching **Data360** segment.

On each run, for each configuration, the framework:
1. executes a `GROUP BY` query on the configured DMO field (via the
[sfsqlquery](https://developer.salesforce.com/docs/platform/apex-ref/references/apex-ref/apex-namespace-sfsqlquery.html)
Apex namespace) to get the current distinct segment name values;
2. lists all the existing segments of the data space (via
[ConnectApi.CdpSegment.getSegmentsPaginated()](https://developer.salesforce.com/docs/platform/apex-ref/references/apex-ref/apex-connectapi-cdpsegment-static-methods.html));
3. creates a new **Dbt** segment (via `ConnectApi.CdpSegment.createSegment()`) for each
value which has no segment with the same name yet.

ℹ️ The framework only **creates** segments. It never updates, deactivates nor deletes
existing segments, even when their value disappears from the DMO.


## Framework Components

| Component | Type | Role |
|---|---|---|
| `sfpegMcnSegmentSyncConfig__mdt` | Custom Metadata Type | One record per DMO / data space to synchronise (see [Configuration Metadata](#configuration-metadata)) |
| `sfpegMcnDmoSegmentSync_SCH` | Apex Class (`Schedulable`) | Entry point to schedule. Enqueues the queueable job for the active configurations |
| `sfpegMcnDmoSegmentSync_QUE` | Apex Class (`Queueable`) | Processes one configuration per job, then chains itself for the remaining ones (each configuration gets its own governor limits) |
| `sfpegMcnDmoSegmentSync_SVC` | Apex Class | Core logic: query, existing segment lookup, segment creation |
| `sfpegMcnDmoSegmentSync_TST` | Apex Test Class | Unit tests (mocking the queries with `sfsqlquery.SqlTester` and the segment API with a stub) |

```
sfpegMcnDmoSegmentSync_SCH.execute()
 └─ sfpegMcnDmoSegmentSync_SCH.run(configNames)        (also callable on demand)
     └─ System.enqueueJob(sfpegMcnDmoSegmentSync_QUE)    (1 job per configuration, chained)
         └─ sfpegMcnDmoSegmentSync_SVC.sync(config)
             ├─ queryDistinctValues()       → sfsqlquery GROUP BY
             ├─ loadExistingSegments()      → ConnectApi.CdpSegment.getSegmentsPaginated()
             └─ createSegment()             → ConnectApi.CdpSegment.createSegment()
```


## Configuration Metadata

Each DMO field to synchronise is described by a record of the **Segment Sync Config**
(`sfpegMcnSegmentSyncConfig__mdt`) custom metadata type, created in **Setup > Custom Metadata Types**
(or deployed as `customMetadata` source files, see [below](#deploying-configurations-as-source)).

### Fields

| Field | API Name | Required | Description |
|---|---|---|---|
| Label / Name | `MasterLabel` / `DeveloperName` | ✅ | Identifies the configuration. The `DeveloperName` is used to run a subset of configurations and appears in logs |
| Active | `IsActive__c` | | Only active configurations are processed (default `false`) |
| Data Space | `DataSpace__c` | ✅ | API name of the **Data360** data space, both for the DMO query and the segments (e.g. `default`) |
| Source DMO | `SourceDmo__c` | ✅ | API name of the DMO queried to identify the segment names (e.g. `SegmentAssignment__dlm`) |
| Segment Name Field | `SegmentNameField__c` | ✅ | API name of the DMO field containing the segment names (e.g. `SegmentName__c`) |
| Segment On | `SegmentOnApiName__c` | ✅ | API name of the entity the created segments are built on (e.g. `UnifiedIndividual__dlm`, `ssot__Individual__dlm`) |
| Segment SQL Template | `SegmentSqlTemplate__c` | ✅ | **Dbt** SQL of the created segments, with placeholders (see [SQL Template](#sql-template)) |
| Segment Name Template | `SegmentNameTemplate__c` | | Template of the display name of the created segments, which must contain `{segmentValue}` (e.g. `EMEA - {segmentValue}`). Left empty = the DMO value itself |
| Segment Description | `SegmentDescription__c` | | Description set on the created segments. Supports the `{segmentValue}` and `{segmentName}` (resulting segment display name) placeholders |
| Publish Schedule | `PublishSchedule__c` | | Publish schedule set on the created segments: `One` (hourly), `Four`, `Twelve` or `TwentyFour` hours. Left empty = no publish schedule |
| Publish Schedule Duration (days) | `PublishScheduleDuration__c` | | Duration of the publish schedule of the created segments, default `365`. The schedule starts at the next full hour (GMT) after creation. Only used when a publish schedule is set |
| Publish On Creation | `PublishOnCreation__c` | | When checked, the created segments are published (ad hoc) as soon as they become active, see [Publication of Created Segments](#publication-of-created-segments) (default `false`) |
| Max Creations Per Run | `MaxCreationsPerRun__c` | | Maximum number of segment creations (successful or failed) per queueable iteration, default `50`. Remaining values are processed in subsequent iterations, requeued automatically (see [Batching and Requeue](#batching-and-requeue)) |

⚠️ `SourceDmo__c`, `SegmentNameField__c` and `SegmentOnApiName__c` must be plain API names
(letters, digits and underscores, starting with a letter). Any other value is rejected
to prevent SQL injection, and the configuration is skipped with an error in the logs.

ℹ️ "Required" is enforced by the custom metadata field definition for the first 4 fields
and by the Apex validation (`sfpegMcnDmoSegmentSync_SVC.validateConfig()`) for the SQL template.

### SQL Template

The `SegmentSqlTemplate__c` field contains the **Dbt** SQL model applied to each created
segment. The following placeholders are replaced at creation time:

| Placeholder | Replaced by | Mandatory |
|---|---|---|
| `{segmentValue}` | The segment name value, with single quotes escaped (`'` → `''`) for use within a SQL string literal | ✅ |
| `{segmentField}` | `SegmentNameField__c` | |
| `{sourceDmo}` | `SourceDmo__c` | |
| `{segmentOn}` | `SegmentOnApiName__c` | |

Example:
```sql
SELECT u.ssot__Id__c
FROM {segmentOn} u
JOIN {sourceDmo} s ON s.IndividualId__c = u.ssot__Id__c
WHERE s.{segmentField} = '{segmentValue}'
```

⚠️ `{segmentValue}` must always be used **within single quotes**, as only quotes are escaped.

⚠️ The SQL must comply with the **Data360** rules for **Dbt** segment SQL models, which
are only checked when the segment is created. Before activating a configuration, test the
template by creating one segment (e.g. with an on-demand run on a single value, see below)
and check the result in the **Segments** tab.

### Documenting a Configuration

Configurations are metadata and drive segment creation in production. Each record
should therefore be documented as follows:
* **Label**: explicit business name of the synchronisation (e.g. `Loyalty Tiers Sync`)
* **DeveloperName**: stable technical name, never renamed once scheduled jobs reference it
(e.g. `LoyaltyTiers`)
* **Segment Description**: should state that the segment is generated, its source and
its value, so that **Data360** users understand where it comes from, e.g.
`Generated by DMO Segment Sync from SegmentAssignment__dlm.SegmentName__c = {segmentValue}`
* the **SQL template** should be kept readable (one clause per line) and reviewed together
with the DMO data model owner.

It is also recommended to list the active configurations of the Org in the project
documentation with: their source DMO / field, their data space, their segment-on entity,
their publish schedule and their business owner.

### Deploying Configurations as Source

Configuration records may be deployed with the rest of the project as
`force-app/main/default/customMetadata/sfpegMcnSegmentSyncConfig.<DeveloperName>.md-meta.xml` files:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<CustomMetadata xmlns="http://soap.sforce.com/2006/04/metadata" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xmlns:xsd="http://www.w3.org/2001/XMLSchema">
    <label>Loyalty Tiers Sync</label>
    <protected>false</protected>
    <values><field>IsActive__c</field><value xsi:type="xsd:boolean">true</value></values>
    <values><field>DataSpace__c</field><value xsi:type="xsd:string">default</value></values>
    <values><field>SourceDmo__c</field><value xsi:type="xsd:string">SegmentAssignment__dlm</value></values>
    <values><field>SegmentNameField__c</field><value xsi:type="xsd:string">SegmentName__c</value></values>
    <values><field>SegmentOnApiName__c</field><value xsi:type="xsd:string">UnifiedIndividual__dlm</value></values>
    <values><field>SegmentSqlTemplate__c</field><value xsi:type="xsd:string">SELECT u.ssot__Id__c FROM {segmentOn} u JOIN {sourceDmo} s ON s.IndividualId__c = u.ssot__Id__c WHERE s.{segmentField} = '{segmentValue}'</value></values>
    <values><field>SegmentDescription__c</field><value xsi:type="xsd:string">Generated by DMO Segment Sync from SegmentAssignment__dlm.SegmentName__c = {segmentValue}</value></values>
    <values><field>PublishSchedule__c</field><value xsi:type="xsd:string">TwentyFour</value></values>
    <values><field>MaxCreationsPerRun__c</field><value xsi:type="xsd:double">50</value></values>
</CustomMetadata>
```


## Behaviour Details

### Segment Matching

* A DMO value matches an existing segment when its segment name (the value itself, or the
result of `SegmentNameTemplate__c`) is equal to the segment **display name**, ignoring case
and leading / trailing spaces.
* Null and blank DMO values are ignored.
* All segments of the data space are considered, whatever their type or segment-on entity.

⚠️ Segments created manually with a display name different from the DMO value (e.g.
`Gold Tier` for the `Gold` value) are not matched, and a new `Gold` segment is created.

### Created Segments

| Segment property | Value |
|---|---|
| Display name | The DMO value, or `SegmentNameTemplate__c` with `{segmentValue}` replaced by the DMO value |
| Developer name | Derived from the display name: non alphanumeric characters replaced by `_`, prefixed by `Seg_` if not starting with a letter, truncated to 40 characters, suffixed by `_1`, `_2`... if already used in the data space. If Data360 still rejects the name as already taken (e.g. used by a segment not listed in the data space), the creation is retried with the next suffix, up to 5 attempts |
| Type | `Dbt` (the only type supported by `ConnectApi.CdpSegment.createSegment()`) |
| Segment on | `SegmentOnApiName__c` |
| SQL model | `SegmentSqlTemplate__c` with placeholders replaced (model name = developer name) |
| Description | `SegmentDescription__c` |
| Publish schedule | `PublishSchedule__c`, starting at the next full hour and ending after `PublishScheduleDuration__c` days (Data360 requires both dates, in the `yyyy-MM-dd'T'HH:mm:ss.SSS'Z'` format, whenever a schedule is set) |

### Publication of Created Segments

When `PublishOnCreation__c` is checked, each created segment is published once, right after
its creation, via `ConnectApi.CdpSegment.executePublishAdhoc()`. This is in addition to its
optional publish schedule (`PublishSchedule__c`), so that its members are available
without waiting for the first scheduled publication.

As **Data360** only allows publishing `ACTIVE` segments, and a newly created segment
remains in `PROCESSING` status for a short while, publication is done in a dedicated
phase of the queueable chain:
* the ids of the created segments are carried along the chain, across configurations;
* once all configurations are processed, a publication job is enqueued with a 1 minute
delay (`PUBLISH_DELAY_MINUTES`);
* it publishes the segments which became `ACTIVE`, and requeues itself (again with a
1 minute delay) for the ones still `PROCESSING`;
* segments in any other status, or whose publication fails, are logged (`WARN`) and dropped;
* after 10 attempts (`MAX_PUBLISH_ATTEMPTS`), the remaining segments are logged (`ERROR`) and
left unpublished. They are then published by their publish schedule, or may be published
manually.

### Error Handling

* A failing segment creation is logged and does not prevent the creation of the other
segments of the configuration. It is retried on the next run.
* A failing configuration (invalid configuration, query error...) is logged and does not
prevent the processing of the other configurations.
* Values are processed in alphabetical order, and at most `MaxCreationsPerRun__c` creations
are attempted per queueable iteration. The remaining values are listed as `postponed` in the logs.

### Batching and Requeue

A single scheduled run processes **all** the missing segments of all the configurations,
through a chain of `sfpegMcnDmoSegmentSync_QUE` queueable jobs:
* when an iteration leaves `postponed` values (max creations reached), the job re-enqueues
itself **on the same configuration** for a new iteration (with fresh governor limits),
which re-runs the DMO query and the existing segments lookup and creates the next batch;
* values whose creation failed during the run are passed to the next iterations and
**skipped** (listed as `skipped` in the logs), so that a failing value cannot loop forever.
They are retried on the next scheduled run;
* once a configuration has no postponed value left, the job moves to the next configuration;
* as a safety net, a configuration is processed in at most 100 iterations per run
(`MAX_ITERATIONS_PER_CONFIG`). Remaining values are then left for the next scheduled run
and an `ERROR` log is issued.

Example with 5 missing values (`A` to `E`), `MaxCreationsPerRun__c = 2` and a failing `B`:

| Iteration | Created | Failed | Skipped | Postponed | Next job |
|---|---|---|---|---|---|
| 1 | `A` | `B` | | `C`, `D`, `E` | same configuration, iteration 2 |
| 2 | `C`, `D` | | `B` | `E` | same configuration, iteration 3 |
| 3 | `E` | | `B` | | next configuration (if any) |

### Logs

Each configuration run produces an `INFO` debug log line such as:
```
sfpegMcnDmoSegmentSync[LoyaltyTiers]: 3 DMO value(s), 1 existing, 2 created [Bronze (Bronze), Silver (Silver)], 0 postponed, 0 skipped (failed in previous iteration), 0 error(s) {}
```
Configuration level failures are logged at `ERROR` level with their stack trace.
To monitor runs, set a **debug log** trace flag on the user running the scheduled job.

All log lines are prefixed by `<ClassName>.<methodName>:` and use the following patterns:

| Pattern | Level | Content |
|---|---|---|
| `... START with ...` | `DEBUG` / `FINE` | Method entry, with its input parameters |
| `... END with ...` | `DEBUG` / `FINE` | Method exit, with its output (or `END KO` on validation failure) |
| `... STEP n - ...` | `DEBUG` | Major processing steps of `sfpegMcnDmoSegmentSync_SVC.sync()` (1. DMO query, 2. existing segments load, 3. segment creations) |
| other messages | `DEBUG` / `FINE` / `WARN` / `ERROR` | Details (SQL executed, segment created, value postponed, creation failure...) |

The **Apex Code** log level of the trace flag controls the verbosity:
* `DEBUG`: entry / exit of the main methods, major steps, SQL executed and segments created;
* `FINE` (or finer): adds the low level helper methods (developer name generation, template
merge, config validation), each segment page fetched and each value skipped or postponed.

ℹ️ Segment SQL models and DMO values are logged in full: keep the log level at `DEBUG` in
production if they may contain sensitive data.


## Scheduling and Running

### Scheduling

All active configurations, every day at 2 AM:
```apex
System.schedule('DMO Segment Sync', '0 0 2 * * ?', new sfpegMcnDmoSegmentSync_SCH());
```

Only some configurations (by `DeveloperName`), every hour:
```apex
System.schedule('DMO Segment Sync - Loyalty', '0 0 * * * ?',
    new sfpegMcnDmoSegmentSync_SCH(new Set<String>{ 'LoyaltyTiers' }));
```

ℹ️ Scheduled jobs are visible in **Setup > Scheduled Jobs**, and the queueable jobs they
launch in **Setup > Apex Jobs**.

### On-Demand Run

From **Anonymous Apex** (returns the queued job Id, or `null` if no active configuration matches):
```apex
sfpegMcnDmoSegmentSync_SCH.run(null);                                  // all active configurations
sfpegMcnDmoSegmentSync_SCH.run(new Set<String>{ 'LoyaltyTiers' });     // a single configuration
```

### Running User

The jobs run with the permissions of the user who scheduled or enqueued them. This user
must have access to **Data360**, to the configured data space(s) and DMO(s), and the
permission to create segments.


## Testing

`sfpegMcnDmoSegmentSync_TST` covers the whole framework without any **Data360** data:
* DMO query results are mocked with `sfsqlquery.SqlTester` (`setMockMetadata()` /
`setMockRows()`, rows being provided via the `ConnectApi.QuerySqlRow.row` property);
* segment API calls are mocked by injecting a stub implementation of the
`sfpegMcnDmoSegmentSync_SVC.SegmentApi` interface in the `sfpegMcnDmoSegmentSync_SVC.segmentApi`
static variable.

ℹ️ As configurations are custom metadata records, tests build `sfpegMcnSegmentSyncConfig__mdt`
records in memory and call `sfpegMcnDmoSegmentSync_SVC.sync()` directly.


## Limitations

* Segments are only created, never updated, deactivated nor deleted.
* Each configuration is processed in a single transaction: the number of distinct DMO values
and of existing segments in the data space must remain compatible with Apex governor limits
(synchronous `sfsqlquery.SqlRowIterator` query, one `getSegmentsPaginated()` call per 200 segments).
* The SQL template is only validated by **Data360** at segment creation time.
