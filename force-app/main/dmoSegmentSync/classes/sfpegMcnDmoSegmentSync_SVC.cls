/***
* @description  Synchronises Data 360 segments with the distinct values of a DMO field.
*               For each sfpegMcnSegmentSyncConfig__mdt record:
*               1. runs a GROUP BY query (sfsqlquery) on the configured DMO / field in the configured
*                  DataSpace to get the current distinct segment name values;
*               2. lists the existing Data 360 segments of the DataSpace
*                  (ConnectApi.CdpSegment.getSegmentsPaginated);
*               3. creates a DBT segment (ConnectApi.CdpSegment.createSegment) for every value which has
*                  no segment with the same display name yet.
*               ConnectApi calls go through the SegmentApi interface so that they can be mocked in tests.
*               Part of the PEG_MCN package.
* @author       P-E GROS
* @date         Nov. 2026
* @see          sfpegMcnDmoSegmentSync_TST
* @see          sfpegMcnDmoSegmentSync_QUE
* @see          sfpegMcnDmoSegmentSyncConfig__mdt
* @see          PEG_MCN package (https://github.com/pegros/PEG_MCN)
*
* Legal Notice
*
* MIT License
*
* Copyright (c) 2026 pegros
*
* Permission is hereby granted, free of charge, to any person obtaining a copy
* of this software and associated documentation files (the "Software"), to deal
* in the Software without restriction, including without limitation the rights
* to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
* copies of the Software, and to permit persons to whom the Software is
* furnished to do so, subject to the following conditions:
*
* The above copyright notice and this permission notice shall be included in all
* copies or substantial portions of the Software.
*
* THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
* IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
* FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
* AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
* LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
* OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
* SOFTWARE.
***/

public with sharing class sfpegMcnDmoSegmentSync_SVC {
    @TestVisible
    private static final Integer SEGMENT_PAGE_SIZE = 200;
    @TestVisible
    private static final Integer DEFAULT_MAX_CREATIONS = 50;
    @TestVisible
    private static final Integer DEVELOPER_NAME_MAX_LENGTH = 40;
    @TestVisible
    private static final String WORKLOAD_NAME = 'dmo_segment_sync';
    @TestVisible
    private static final Integer DEFAULT_PUBLISH_DURATION_DAYS = 365;
    @TestVisible
    private static final Integer MAX_NAME_ATTEMPTS = 5;
    @TestVisible
    private static final String SEGMENT_STATUS_ACTIVE = 'ACTIVE';
    @TestVisible
    private static final String SEGMENT_STATUS_PROCESSING = 'PROCESSING';
    @TestVisible
    private static final String PUBLISH_DATETIME_FORMAT = 'yyyy-MM-dd\'T\'HH:mm:ss.SSS\'Z\'';

    // Only allow plain API names in the generated SQL (prevents SQL injection via config).
    private static final Pattern IDENTIFIER_PATTERN = Pattern.compile('^[A-Za-z][A-Za-z0-9_]*$');

    //----------------------------------------------------------------------------------------
    // Segment API abstraction (mockable in tests)
    //----------------------------------------------------------------------------------------

    /** @description Abstraction of the ConnectApi.CdpSegment methods used. */
    public interface SegmentApi {
        ConnectApi.CdpSegmentContainerOutput getSegmentsPaginated(
            Integer batchSize,
            Integer offset,
            String orderBy,
            String dataspace
        );
        ConnectApi.CdpSegmentOutput createSegment(ConnectApi.CdpSegmentInput input, String dataspace);
        ConnectApi.CdpSegmentContainerOutput getSegmentById(String segmentId);
        ConnectApi.CdpSegmentActionOutput executePublishAdhoc(String segmentId);
    }

    /** @description Default implementation delegating to ConnectApi.CdpSegment. */
    public class ConnectSegmentApi implements SegmentApi {
        public ConnectApi.CdpSegmentContainerOutput getSegmentsPaginated(
            Integer batchSize,
            Integer offset,
            String orderBy,
            String dataspace
        ) {
            System.debug(LoggingLevel.FINE, 'sfpegMcnDmoSegmentSync_SVC.ConnectSegmentApi.getSegmentsPaginated: START with batchSize ' + batchSize + ' / offset ' + offset + ' / orderBy ' + orderBy + ' / dataspace ' + dataspace);
            ConnectApi.CdpSegmentContainerOutput output = ConnectApi.CdpSegment.getSegmentsPaginated(batchSize, offset, orderBy, dataspace);
            System.debug(LoggingLevel.FINE, 'sfpegMcnDmoSegmentSync_SVC.ConnectSegmentApi.getSegmentsPaginated: END with #segments ' + (output?.segments == null ? 0 : output.segments.size()));
            return output;
        }
        public ConnectApi.CdpSegmentOutput createSegment(ConnectApi.CdpSegmentInput input, String dataspace) {
            System.debug(LoggingLevel.FINE, 'sfpegMcnDmoSegmentSync_SVC.ConnectSegmentApi.createSegment: START with developerName ' + input?.developerName + ' / dataspace ' + dataspace);
            ConnectApi.CdpSegmentOutput output = ConnectApi.CdpSegment.createSegment(input, dataspace);
            System.debug(LoggingLevel.FINE, 'sfpegMcnDmoSegmentSync_SVC.ConnectSegmentApi.createSegment: END with apiName ' + output?.apiName + ' / segmentId ' + output?.marketSegmentId + ' / status ' + output?.segmentStatus);
            return output;
        }
        public ConnectApi.CdpSegmentContainerOutput getSegmentById(String segmentId) {
            System.debug(LoggingLevel.FINE, 'sfpegMcnDmoSegmentSync_SVC.ConnectSegmentApi.getSegmentById: START with segmentId ' + segmentId);
            ConnectApi.CdpSegmentContainerOutput output = ConnectApi.CdpSegment.getSegmentById(segmentId);
            System.debug(LoggingLevel.FINE, 'sfpegMcnDmoSegmentSync_SVC.ConnectSegmentApi.getSegmentById: END with #segments ' + (output?.segments == null ? 0 : output.segments.size()));
            return output;
        }
        public ConnectApi.CdpSegmentActionOutput executePublishAdhoc(String segmentId) {
            System.debug(LoggingLevel.FINE, 'sfpegMcnDmoSegmentSync_SVC.ConnectSegmentApi.executePublishAdhoc: START with segmentId ' + segmentId);
            ConnectApi.CdpSegmentActionOutput output = ConnectApi.CdpSegment.executePublishAdhoc(segmentId);
            System.debug(LoggingLevel.FINE, 'sfpegMcnDmoSegmentSync_SVC.ConnectSegmentApi.executePublishAdhoc: END with jobId ' + output?.jobId + ' / publishStatus ' + output?.publishStatus);
            return output;
        }
    }

    @TestVisible
    private static SegmentApi segmentApi = new ConnectSegmentApi();

    /** @description Configurations to use instead of the custom metadata records (tests only). */
    @TestVisible
    private static Map<String, sfpegMcnSegmentSyncConfig__mdt> testConfigs;

    //----------------------------------------------------------------------------------------
    // Result reporting
    //----------------------------------------------------------------------------------------

    /** @description Outcome of the synchronisation of one configuration. */
    public class SyncResult {
        public String configName;
        public Set<String> dmoValues = new Set<String>();
        public List<String> existing = new List<String>();
        public List<String> created = new List<String>();
        /** @description marketSegmentId of the created segments (to be published if requested). */
        public List<String> createdIds = new List<String>();
        public List<String> postponed = new List<String>();
        public List<String> skipped = new List<String>();
        public Map<String, String> errors = new Map<String, String>();

        /** @description true when some values still have to be processed in a next iteration. */
        public Boolean hasRemaining() {
            return !postponed.isEmpty();
        }

        public override String toString() {
            return 'sfpegMcnDmoSegmentSync[' + configName + ']: ' +
                dmoValues.size() + ' DMO value(s), ' +
                existing.size() + ' existing, ' +
                created.size() + ' created ' + created + ', ' +
                postponed.size() + ' postponed, ' +
                skipped.size() + ' skipped (failed in previous iteration), ' +
                errors.size() + ' error(s) ' + errors;
        }
    }

    //----------------------------------------------------------------------------------------
    // Configuration
    //----------------------------------------------------------------------------------------

    /**
     * @description Returns the active configurations, optionally restricted to some DeveloperNames.
     * @param developerNames DeveloperNames to restrict to (null or empty = all active ones)
     */
    public static List<sfpegMcnSegmentSyncConfig__mdt> getActiveConfigs(Set<String> developerNames) {
        System.debug('sfpegMcnDmoSegmentSync_SVC.getActiveConfigs: START with developerNames ' + developerNames);
        List<sfpegMcnSegmentSyncConfig__mdt> result = new List<sfpegMcnSegmentSyncConfig__mdt>();
        Map<String, sfpegMcnSegmentSyncConfig__mdt> allConfigs = testConfigs != null ? testConfigs : sfpegMcnSegmentSyncConfig__mdt.getAll();
        System.debug(LoggingLevel.FINE, 'sfpegMcnDmoSegmentSync_SVC.getActiveConfigs: #configs defined ' + allConfigs.size());
        for (sfpegMcnSegmentSyncConfig__mdt config : allConfigs.values()) {
            if (
                config.IsActive__c &&
                (developerNames == null || developerNames.isEmpty() || developerNames.contains(config.DeveloperName))
            ) {
                result.add(config);
            }
            else {
                System.debug(LoggingLevel.FINE, 'sfpegMcnDmoSegmentSync_SVC.getActiveConfigs: config ignored (inactive or not requested) ' + config.DeveloperName);
            }
        }
        System.debug('sfpegMcnDmoSegmentSync_SVC.getActiveConfigs: END with #configs ' + result.size() + ' ' + getNames(result));
        return result;
    }

    //----------------------------------------------------------------------------------------
    // Main logic
    //----------------------------------------------------------------------------------------

    /**
     * @description Synchronises the segments of one configuration.
     * @param config configuration to process
     * @return the synchronisation outcome (also logged)
     */
    public static SyncResult sync(sfpegMcnSegmentSyncConfig__mdt config) {
        return sync(config, null);
    }

    /**
     * @description Synchronises the segments of one configuration, ignoring some values.
     * Used by the queueable when re-processing a configuration in a next iteration, to avoid
     * retrying (in a loop) values whose creation already failed during the same run.
     * @param config configuration to process
     * @param excludedValues segment name values not to process (null = none)
     * @return the synchronisation outcome (also logged)
     */
    public static SyncResult sync(sfpegMcnSegmentSyncConfig__mdt config, Set<String> excludedValues) {
        System.debug('sfpegMcnDmoSegmentSync_SVC.sync: START with config ' + config + ' / excludedValues ' + excludedValues);
        validateConfig(config);
        SyncResult result = new SyncResult();
        result.configName = config.DeveloperName;

        System.debug('sfpegMcnDmoSegmentSync_SVC.sync: STEP 1 - querying distinct DMO values');
        result.dmoValues = queryDistinctValues(config);
        if (result.dmoValues.isEmpty()) {
            System.debug(LoggingLevel.INFO, result);
            System.debug('sfpegMcnDmoSegmentSync_SVC.sync: END with no DMO value (no segment to create)');
            return result;
        }

        System.debug('sfpegMcnDmoSegmentSync_SVC.sync: STEP 2 - loading existing segments of data space ' + config.DataSpace__c);
        Set<String> existingDisplayNames = new Set<String>();
        Set<String> existingDeveloperNames = new Set<String>();
        loadExistingSegments(config.DataSpace__c, existingDisplayNames, existingDeveloperNames);

        Integer maxCreations = config.MaxCreationsPerRun__c == null || config.MaxCreationsPerRun__c < 1
            ? DEFAULT_MAX_CREATIONS
            : config.MaxCreationsPerRun__c.intValue();
        System.debug('sfpegMcnDmoSegmentSync_SVC.sync: STEP 3 - creating missing segments (max ' + maxCreations + ' creations)');

        List<String> sortedValues = new List<String>(result.dmoValues);
        sortedValues.sort();
        for (String value : sortedValues) {
            String segmentName = buildSegmentName(config, value);
            if (existingDisplayNames.contains(segmentName.toLowerCase())) {
                System.debug(LoggingLevel.FINE, 'sfpegMcnDmoSegmentSync_SVC.sync: segment already existing for value ' + value + ' with name ' + segmentName);
                result.existing.add(value);
                continue;
            }
            if (excludedValues != null && excludedValues.contains(value)) {
                System.debug(LoggingLevel.FINE, 'sfpegMcnDmoSegmentSync_SVC.sync: value skipped (failed in previous iteration) ' + value);
                result.skipped.add(value);
                continue;
            }
            if (result.created.size() + result.errors.size() >= maxCreations) {
                System.debug(LoggingLevel.FINE, 'sfpegMcnDmoSegmentSync_SVC.sync: max creations reached, postponing value ' + value);
                result.postponed.add(value);
                continue;
            }
            try {
                System.debug('sfpegMcnDmoSegmentSync_SVC.sync: creating segment for value ' + value + ' with name ' + segmentName);
                String developerName = buildDeveloperName(segmentName, existingDeveloperNames);
                ConnectApi.CdpSegmentOutput output = null;
                Integer attempt = 1;
                while (output == null) {
                    try {
                        output = segmentApi.createSegment(
                            buildSegmentInput(config, value, segmentName, developerName),
                            config.DataSpace__c
                        );
                    } catch (Exception e) {
                        // Developer names may be used outside of the data space (or by not listed segments).
                        if (attempt >= MAX_NAME_ATTEMPTS || !isDuplicateNameError(e)) {
                            throw e;
                        }
                        System.debug(LoggingLevel.WARN, 'sfpegMcnDmoSegmentSync_SVC.sync: developer name already taken ' + developerName + ', retrying with another one');
                        existingDeveloperNames.add(developerName.toLowerCase());
                        developerName = buildDeveloperName(segmentName, existingDeveloperNames);
                        attempt++;
                    }
                }
                existingDeveloperNames.add(developerName.toLowerCase());
                existingDisplayNames.add(segmentName.toLowerCase());
                if (String.isNotBlank(output?.marketSegmentId)) {
                    result.createdIds.add(output.marketSegmentId);
                }
                result.created.add(segmentName + (output?.apiName == null ? '' : ' (' + output.apiName + ')'));
                System.debug('sfpegMcnDmoSegmentSync_SVC.sync: segment created for value ' + value + ' with apiName ' + output?.apiName);
            } catch (Exception e) {
                // One failing segment must not prevent the creation of the other ones.
                System.debug(LoggingLevel.WARN, 'sfpegMcnDmoSegmentSync_SVC.sync: segment creation failed for value ' + value + ': ' + e.getTypeName() + ': ' + e.getMessage());
                result.errors.put(value, e.getTypeName() + ': ' + e.getMessage());
            }
        }

        System.debug(LoggingLevel.INFO, result);
        System.debug('sfpegMcnDmoSegmentSync_SVC.sync: END with #created ' + result.created.size() + ' / #existing ' + result.existing.size() + ' / #postponed ' + result.postponed.size() + ' / #skipped ' + result.skipped.size() + ' / #errors ' + result.errors.size());
        return result;
    }

    //----------------------------------------------------------------------------------------
    // Segment publication
    //----------------------------------------------------------------------------------------

    /**
     * @description Publishes (ad hoc) the segments which are active. Segments still being processed
     * after their creation (status PROCESSING) are returned to be retried later, other ones
     * (published, failed or in an unexpected status) are logged and dropped.
     * @param segmentIds marketSegmentId of the segments to publish
     * @return the segmentIds still pending (not active yet)
     */
    public static List<String> publishActiveSegments(List<String> segmentIds) {
        System.debug('sfpegMcnDmoSegmentSync_SVC.publishActiveSegments: START with segmentIds ' + segmentIds);
        List<String> pending = new List<String>();
        if (segmentIds == null) {
            System.debug('sfpegMcnDmoSegmentSync_SVC.publishActiveSegments: END with no segment');
            return pending;
        }
        Integer published = 0;
        for (String segmentId : segmentIds) {
            try {
                ConnectApi.CdpSegmentContainerOutput container = segmentApi.getSegmentById(segmentId);
                ConnectApi.CdpSegmentOutput segment = container?.segments == null || container.segments.isEmpty()
                    ? null
                    : container.segments[0];
                String status = segment?.segmentStatus;
                if (status == SEGMENT_STATUS_ACTIVE) {
                    ConnectApi.CdpSegmentActionOutput action = segmentApi.executePublishAdhoc(segmentId);
                    if (String.isNotBlank(action?.errorCode) || String.isNotBlank(action?.errorMessage)) {
                        System.debug(LoggingLevel.WARN, 'sfpegMcnDmoSegmentSync_SVC.publishActiveSegments: publication failed for ' + segmentId + ': ' + action.errorCode + ' ' + action.errorMessage);
                    }
                    else {
                        published++;
                        System.debug('sfpegMcnDmoSegmentSync_SVC.publishActiveSegments: segment published ' + segment.apiName + ' (' + segmentId + ') with job ' + action?.jobId + ' / status ' + action?.publishStatus);
                    }
                }
                else if (status == SEGMENT_STATUS_PROCESSING) {
                    System.debug(LoggingLevel.FINE, 'sfpegMcnDmoSegmentSync_SVC.publishActiveSegments: segment not active yet ' + segment.apiName + ' (' + segmentId + ')');
                    pending.add(segmentId);
                }
                else {
                    System.debug(LoggingLevel.WARN, 'sfpegMcnDmoSegmentSync_SVC.publishActiveSegments: segment ' + segmentId + ' not published, unexpected status ' + status);
                }
            } catch (Exception e) {
                System.debug(LoggingLevel.WARN, 'sfpegMcnDmoSegmentSync_SVC.publishActiveSegments: publication failed for ' + segmentId + ': ' + e.getTypeName() + ': ' + e.getMessage());
            }
        }
        System.debug('sfpegMcnDmoSegmentSync_SVC.publishActiveSegments: END with #published ' + published + ' / #pending ' + pending.size());
        return pending;
    }

    /**
     * @description Runs the GROUP BY query returning the distinct non empty segment name values.
     */
    @TestVisible
    private static Set<String> queryDistinctValues(sfpegMcnSegmentSyncConfig__mdt config) {
        System.debug('sfpegMcnDmoSegmentSync_SVC.queryDistinctValues: START for config ' + config.DeveloperName);
        String field = config.SegmentNameField__c;
        String sql =
            'SELECT ' + field + ' FROM ' + config.SourceDmo__c +
            ' WHERE ' + field + ' IS NOT NULL GROUP BY ' + field;
        System.debug('sfpegMcnDmoSegmentSync_SVC.queryDistinctValues: executing SQL ' + sql + ' in data space ' + config.DataSpace__c);

        Set<String> values = new Set<String>();
        Integer rowCount = 0;
        sfsqlquery.SqlRowIterator rows = sfsqlquery.SqlStatement.create(sql, config.DataSpace__c)
            .withWorkloadName(WORKLOAD_NAME)
            .execute();
        for (sfsqlquery.Row row : rows) {
            rowCount++;
            String value = row.getString(0)?.trim();
            if (String.isNotBlank(value)) {
                values.add(value);
            }
            else {
                System.debug(LoggingLevel.FINE, 'sfpegMcnDmoSegmentSync_SVC.queryDistinctValues: blank value ignored');
            }
        }
        System.debug('sfpegMcnDmoSegmentSync_SVC.queryDistinctValues: #rows fetched ' + rowCount);
        System.debug('sfpegMcnDmoSegmentSync_SVC.queryDistinctValues: END with #values ' + values.size() + ' ' + values);
        return values;
    }

    /**
     * @description Pages through all segments of the DataSpace and collects their (lower-cased)
     * display names and developer names.
     */
    @TestVisible
    private static void loadExistingSegments(
        String dataSpace,
        Set<String> displayNames,
        Set<String> developerNames
    ) {
        System.debug('sfpegMcnDmoSegmentSync_SVC.loadExistingSegments: START for data space ' + dataSpace);
        Integer offset = 0;
        Integer pageCount = 0;
        while (true) {
            pageCount++;
            System.debug(LoggingLevel.FINE, 'sfpegMcnDmoSegmentSync_SVC.loadExistingSegments: fetching page ' + pageCount + ' at offset ' + offset);
            ConnectApi.CdpSegmentContainerOutput page = segmentApi.getSegmentsPaginated(
                SEGMENT_PAGE_SIZE,
                offset,
                'Name ASC',
                dataSpace
            );
            List<ConnectApi.CdpSegmentOutput> segments = page?.segments;
            if (segments == null || segments.isEmpty()) {
                System.debug(LoggingLevel.FINE, 'sfpegMcnDmoSegmentSync_SVC.loadExistingSegments: empty page, stopping');
                break;
            }
            System.debug(LoggingLevel.FINE, 'sfpegMcnDmoSegmentSync_SVC.loadExistingSegments: #segments in page ' + segments.size());
            for (ConnectApi.CdpSegmentOutput segment : segments) {
                if (String.isNotBlank(segment.displayName)) {
                    displayNames.add(segment.displayName.trim().toLowerCase());
                }
                if (String.isNotBlank(segment.developerName)) {
                    developerNames.add(segment.developerName.toLowerCase());
                }
                if (String.isNotBlank(segment.apiName)) {
                    developerNames.add(segment.apiName.toLowerCase());
                }
            }
            if (segments.size() < SEGMENT_PAGE_SIZE) {
                System.debug(LoggingLevel.FINE, 'sfpegMcnDmoSegmentSync_SVC.loadExistingSegments: last page reached');
                break;
            }
            offset += segments.size();
        }
        System.debug('sfpegMcnDmoSegmentSync_SVC.loadExistingSegments: END with #pages ' + pageCount + ' / #display names ' + displayNames.size() + ' / #developer names ' + developerNames.size());
        System.debug(LoggingLevel.FINE, 'sfpegMcnDmoSegmentSync_SVC.loadExistingSegments: display names ' + displayNames);
    }

    /**
     * @description Builds the DBT segment creation input for a segment name value.
     */
    @TestVisible
    private static ConnectApi.CdpSegmentInput buildSegmentInput(
        sfpegMcnSegmentSyncConfig__mdt config,
        String value,
        String segmentName,
        String developerName
    ) {
        System.debug('sfpegMcnDmoSegmentSync_SVC.buildSegmentInput: START with value ' + value + ' / segmentName ' + segmentName + ' / developerName ' + developerName);
        ConnectApi.CdpSegmentDbtModelInput model = new ConnectApi.CdpSegmentDbtModelInput();
        model.name = developerName;
        model.sql = mergeTemplate(config.SegmentSqlTemplate__c, config, value);

        ConnectApi.CdpSegmentDbtInput dbt = new ConnectApi.CdpSegmentDbtInput();
        dbt.models = new List<ConnectApi.CdpSegmentDbtModelInput>{ model };

        ConnectApi.CdpSegmentInput input = new ConnectApi.CdpSegmentInput();
        input.developerName = developerName;
        input.displayName = segmentName;
        input.segmentType = ConnectApi.SegmentType.Dbt;
        input.segmentOnApiName = config.SegmentOnApiName__c;
        input.includeDbt = dbt;
        if (String.isNotBlank(config.SegmentDescription__c)) {
            input.description = config.SegmentDescription__c.replace('{segmentValue}', value).replace('{segmentName}', segmentName);
        }
        if (String.isNotBlank(config.PublishSchedule__c)) {
            input.publishSchedule = ConnectApi.PublishSchedule.valueOf(config.PublishSchedule__c);
            // Data360 requires both start datetime and end date along with a publish schedule.
            Datetime startTime = getNextFullHour(Datetime.now());
            Integer durationDays = config.PublishScheduleDuration__c == null || config.PublishScheduleDuration__c < 1
                ? DEFAULT_PUBLISH_DURATION_DAYS
                : config.PublishScheduleDuration__c.intValue();
            // Both values must be in the yyyy-MM-dd'T'HH:mm:ss.SSS'Z' format (end date included).
            input.publishScheduleStartDateTime = startTime.formatGmt(PUBLISH_DATETIME_FORMAT);
            input.publishScheduleEndDate = startTime.addDays(durationDays).formatGmt(PUBLISH_DATETIME_FORMAT);
        }
        System.debug('sfpegMcnDmoSegmentSync_SVC.buildSegmentInput: END with segmentOn ' + input.segmentOnApiName + ' / publishSchedule ' + input.publishSchedule + ' from ' + input.publishScheduleStartDateTime + ' to ' + input.publishScheduleEndDate + ' / description ' + input.description + ' / SQL ' + model.sql);
        return input;
    }

    /**
     * @description Builds the display name of the segment of a value, applying the optional
     * SegmentNameTemplate__c (the value itself when no template is defined).
     */
    @TestVisible
    private static String buildSegmentName(sfpegMcnSegmentSyncConfig__mdt config, String value) {
        if (String.isBlank(config.SegmentNameTemplate__c)) {
            return value;
        }
        String segmentName = config.SegmentNameTemplate__c.replace('{segmentValue}', value).trim();
        System.debug(LoggingLevel.FINE, 'sfpegMcnDmoSegmentSync_SVC.buildSegmentName: ' + value + ' -> ' + segmentName);
        return segmentName;
    }

    /**
     * @description Replaces the placeholders of the SQL template.
     * {segmentValue} is escaped for use within a single-quoted SQL string literal.
     */
    @TestVisible
    private static String mergeTemplate(String template, sfpegMcnSegmentSyncConfig__mdt config, String value) {
        System.debug(LoggingLevel.FINE, 'sfpegMcnDmoSegmentSync_SVC.mergeTemplate: START with value ' + value + ' / template ' + template);
        String sql = template
            .replace('{segmentField}', config.SegmentNameField__c)
            .replace('{sourceDmo}', config.SourceDmo__c)
            .replace('{segmentOn}', config.SegmentOnApiName__c)
            .replace('{segmentValue}', value.replace('\'', '\'\''));
        System.debug(LoggingLevel.FINE, 'sfpegMcnDmoSegmentSync_SVC.mergeTemplate: END with SQL ' + sql);
        return sql;
    }

    /**
     * @description Derives a valid and unique segment developer name from a segment name value
     * (letters, digits and single underscores, starting with a letter, max 40 characters).
     */
    @TestVisible
    private static String buildDeveloperName(String value, Set<String> existingDeveloperNames) {
        System.debug(LoggingLevel.FINE, 'sfpegMcnDmoSegmentSync_SVC.buildDeveloperName: START with value ' + value + ' / #existing names ' + existingDeveloperNames?.size());
        String base = value.replaceAll('[^A-Za-z0-9]+', '_').replaceAll('^_+|_+$', '');
        if (String.isBlank(base) || !base.substring(0, 1).isAlpha()) {
            base = 'Seg_' + base;
        }
        base = base.left(DEVELOPER_NAME_MAX_LENGTH).removeEnd('_');

        String candidate = base;
        Integer suffix = 1;
        while (existingDeveloperNames.contains(candidate.toLowerCase())) {
            System.debug(LoggingLevel.FINE, 'sfpegMcnDmoSegmentSync_SVC.buildDeveloperName: name already used ' + candidate);
            String tail = '_' + suffix++;
            candidate = base.left(DEVELOPER_NAME_MAX_LENGTH - tail.length()).removeEnd('_') + tail;
        }
        System.debug(LoggingLevel.FINE, 'sfpegMcnDmoSegmentSync_SVC.buildDeveloperName: END with ' + candidate);
        return candidate;
    }

    @TestVisible
    private static void validateConfig(sfpegMcnSegmentSyncConfig__mdt config) {
        String name = config?.DeveloperName;
        System.debug(LoggingLevel.FINE, 'sfpegMcnDmoSegmentSync_SVC.validateConfig: START for config ' + name);
        for (String identifier : new List<String>{
            config?.SourceDmo__c,
            config?.SegmentNameField__c,
            config?.SegmentOnApiName__c
        }) {
            if (identifier == null || !IDENTIFIER_PATTERN.matcher(identifier).matches()) {
                System.debug(LoggingLevel.ERROR, 'sfpegMcnDmoSegmentSync_SVC.validateConfig: END KO - invalid API name ' + identifier);
                throw new SyncException('Invalid API name "' + identifier + '" in configuration ' + name);
            }
        }
        if (String.isBlank(config.DataSpace__c)) {
            System.debug(LoggingLevel.ERROR, 'sfpegMcnDmoSegmentSync_SVC.validateConfig: END KO - missing data space');
            throw new SyncException('Missing DataSpace in configuration ' + name);
        }
        if (String.isBlank(config.SegmentSqlTemplate__c) || !config.SegmentSqlTemplate__c.contains('{segmentValue}')) {
            System.debug(LoggingLevel.ERROR, 'sfpegMcnDmoSegmentSync_SVC.validateConfig: END KO - SQL template without {segmentValue}');
            throw new SyncException('Segment SQL template must contain {segmentValue} in configuration ' + name);
        }
        if (String.isNotBlank(config.SegmentNameTemplate__c) && !config.SegmentNameTemplate__c.contains('{segmentValue}')) {
            System.debug(LoggingLevel.ERROR, 'sfpegMcnDmoSegmentSync_SVC.validateConfig: END KO - segment name template without {segmentValue}');
            throw new SyncException('Segment name template must contain {segmentValue} in configuration ' + name);
        }
        System.debug(LoggingLevel.FINE, 'sfpegMcnDmoSegmentSync_SVC.validateConfig: END OK');
    }

    /** @description Tells whether a segment creation error is due to an already used developer name. */
    @TestVisible
    private static Boolean isDuplicateNameError(Exception e) {
        String message = e.getMessage();
        return message != null && message.containsIgnoreCase('developer name') && message.containsIgnoreCase('already taken');
    }

    /** @description Returns the first full hour (GMT) strictly after the provided time. */
    @TestVisible
    private static Datetime getNextFullHour(Datetime value) {
        Datetime hour = Datetime.newInstanceGmt(value.dateGmt(), Time.newInstance(value.hourGmt(), 0, 0, 0));
        return hour.addHours(1);
    }

    /** @description Returns the DeveloperNames of a list of configurations (for logs). */
    private static List<String> getNames(List<sfpegMcnSegmentSyncConfig__mdt> configs) {
        List<String> names = new List<String>();
        for (sfpegMcnSegmentSyncConfig__mdt config : configs) {
            names.add(config.DeveloperName);
        }
        return names;
    }

    public class SyncException extends Exception {
    }
}
