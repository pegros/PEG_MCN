/***
* @description  Test class for the DMO Segment sync feature.
*               Part of the PEG_MCN package.
* @author       P-E GROS
* @date         Nov. 2026
* @see          sfpegMcnDmoSegmentSync_SCH
* @see          sfpegMcnDmoSegmentSync_QUE
* @see          sfpegMcnDmoSegmentSync_SVC
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

@IsTest
private class sfpegMcnDmoSegmentSync_TST {
    /** @description In-memory mock of the ConnectApi.CdpSegment methods. */
    private class SegmentApiMock implements sfpegMcnDmoSegmentSync_SVC.SegmentApi {
        List<ConnectApi.CdpSegmentOutput> existing = new List<ConnectApi.CdpSegmentOutput>();
        List<ConnectApi.CdpSegmentInput> createdInputs = new List<ConnectApi.CdpSegmentInput>();
        List<String> createdDataSpaces = new List<String>();
        Set<String> failingDisplayNames = new Set<String>();
        Set<String> takenDeveloperNames = new Set<String>();
        Integer pageCalls = 0;
        Map<String, String> statusById = new Map<String, String>();
        List<String> publishedIds = new List<String>();
        Set<String> publishErrorIds = new Set<String>();

        public ConnectApi.CdpSegmentContainerOutput getSegmentsPaginated(
            Integer batchSize,
            Integer offset,
            String orderBy,
            String dataspace
        ) {
            pageCalls++;
            ConnectApi.CdpSegmentContainerOutput page = new ConnectApi.CdpSegmentContainerOutput();
            page.segments = new List<ConnectApi.CdpSegmentOutput>();
            for (Integer i = offset; i < Math.min(offset + batchSize, existing.size()); i++) {
                page.segments.add(existing[i]);
            }
            return page;
        }

        public ConnectApi.CdpSegmentOutput createSegment(ConnectApi.CdpSegmentInput input, String dataspace) {
            if (failingDisplayNames.contains(input.displayName)) {
                throw new sfpegMcnDmoSegmentSync_SVC.SyncException('creation failure');
            }
            if (takenDeveloperNames.contains(input.developerName)) {
                throw new sfpegMcnDmoSegmentSync_SVC.SyncException('That developer name\'s already taken. Provide a unique name value.');
            }
            createdInputs.add(input);
            createdDataSpaces.add(dataspace);
            ConnectApi.CdpSegmentOutput output = new ConnectApi.CdpSegmentOutput();
            output.apiName = input.developerName;
            output.displayName = input.displayName;
            output.marketSegmentId = 'ID_' + input.developerName;
            output.segmentStatus = 'PROCESSING';
            statusById.put(output.marketSegmentId, 'PROCESSING');
            return output;
        }

        public ConnectApi.CdpSegmentContainerOutput getSegmentById(String segmentId) {
            ConnectApi.CdpSegmentContainerOutput container = new ConnectApi.CdpSegmentContainerOutput();
            container.segments = new List<ConnectApi.CdpSegmentOutput>();
            if (statusById.containsKey(segmentId)) {
                ConnectApi.CdpSegmentOutput output = new ConnectApi.CdpSegmentOutput();
                output.marketSegmentId = segmentId;
                output.apiName = segmentId.removeStart('ID_');
                output.segmentStatus = statusById.get(segmentId);
                container.segments.add(output);
            }
            return container;
        }

        public ConnectApi.CdpSegmentActionOutput executePublishAdhoc(String segmentId) {
            if (publishErrorIds.contains(segmentId)) {
                throw new sfpegMcnDmoSegmentSync_SVC.SyncException('publication failure');
            }
            publishedIds.add(segmentId);
            ConnectApi.CdpSegmentActionOutput output = new ConnectApi.CdpSegmentActionOutput();
            output.segmentId = segmentId;
            output.jobId = 'JOB_' + segmentId;
            output.publishStatus = 'PUBLISHING';
            return output;
        }
    }

    private static SegmentApiMock installMock() {
        SegmentApiMock mock = new SegmentApiMock();
        sfpegMcnDmoSegmentSync_SVC.segmentApi = mock;
        return mock;
    }

    private static ConnectApi.CdpSegmentOutput segment(String displayName, String developerName) {
        ConnectApi.CdpSegmentOutput output = new ConnectApi.CdpSegmentOutput();
        output.displayName = displayName;
        output.developerName = developerName;
        output.apiName = developerName;
        return output;
    }

    private static sfpegMcnSegmentSyncConfig__mdt config() {
        return new sfpegMcnSegmentSyncConfig__mdt(
            DeveloperName = 'TestConfig',
            IsActive__c = true,
            DataSpace__c = 'default',
            SourceDmo__c = 'SegmentAssignment__dlm',
            SegmentNameField__c = 'SegmentName__c',
            SegmentOnApiName__c = 'UnifiedIndividual__dlm',
            SegmentSqlTemplate__c = 'SELECT u.ssot__Id__c FROM {segmentOn} u JOIN {sourceDmo} s ' +
                'ON s.IndividualId__c = u.ssot__Id__c WHERE s.{segmentField} = \'{segmentValue}\'',
            SegmentDescription__c = 'Auto-created for {segmentValue}',
            PublishSchedule__c = 'TwentyFour'
        );
    }

    private static void mockDmoValues(List<Object> values) {
        sfsqlquery.SqlTester.clearMocks();
        ConnectApi.QuerySqlMetadataItem column = new ConnectApi.QuerySqlMetadataItem();
        column.name = 'SegmentName__c';
        column.type = ConnectApi.TypeEnum.VARCHAR;
        sfsqlquery.SqlTester.setMockMetadata(new List<ConnectApi.QuerySqlMetadataItem>{ column });
        List<ConnectApi.QuerySqlRow> rows = new List<ConnectApi.QuerySqlRow>();
        for (Object value : values) {
            ConnectApi.QuerySqlRow row = new ConnectApi.QuerySqlRow();
            row.row = new List<Object>{ value };
            rows.add(row);
        }
        sfsqlquery.SqlTester.setMockRows(rows);
    }

    @IsTest
    static void createsOnlyMissingSegments() {
        mockDmoValues(new List<Object>{ 'Gold', 'Silver', 'Bronze', null, '  ' });
        SegmentApiMock mock = installMock();
        mock.existing.add(segment('gold', 'Gold'));

        Test.startTest();
        sfpegMcnDmoSegmentSync_SVC.SyncResult result = sfpegMcnDmoSegmentSync_SVC.sync(config());
        Test.stopTest();

        Assert.areEqual(new Set<String>{ 'Gold', 'Silver', 'Bronze' }, result.dmoValues);
        Assert.areEqual(new List<String>{ 'Gold' }, result.existing);
        Assert.areEqual(2, mock.createdInputs.size(), 'Bronze and Silver expected');
        Assert.isTrue(result.errors.isEmpty());

        ConnectApi.CdpSegmentInput bronze = mock.createdInputs[0];
        Assert.areEqual('Bronze', bronze.displayName);
        Assert.areEqual('Bronze', bronze.developerName);
        Assert.areEqual(ConnectApi.SegmentType.Dbt, bronze.segmentType);
        Assert.areEqual('UnifiedIndividual__dlm', bronze.segmentOnApiName);
        Assert.areEqual(ConnectApi.PublishSchedule.TwentyFour, bronze.publishSchedule);
        Assert.isNotNull(bronze.publishScheduleStartDateTime, 'Start datetime required with a publish schedule');
        Datetime expectedStart = sfpegMcnDmoSegmentSync_SVC.getNextFullHour(Datetime.now());
        Assert.isTrue(bronze.publishScheduleStartDateTime.endsWith(':00:00.000Z'), bronze.publishScheduleStartDateTime);
        Assert.areEqual(
            expectedStart.addDays(sfpegMcnDmoSegmentSync_SVC.DEFAULT_PUBLISH_DURATION_DAYS).formatGmt(sfpegMcnDmoSegmentSync_SVC.PUBLISH_DATETIME_FORMAT),
            bronze.publishScheduleEndDate
        );
        Assert.areEqual('Auto-created for Bronze', bronze.description);
        Assert.areEqual(1, bronze.includeDbt.models.size());
        Assert.isTrue(bronze.includeDbt.models[0].sql.contains('s.SegmentName__c = \'Bronze\''));
        Assert.isTrue(bronze.includeDbt.models[0].sql.contains('FROM UnifiedIndividual__dlm u'));
        Assert.areEqual('default', mock.createdDataSpaces[0]);
    }

    @IsTest
    static void pagesThroughExistingSegments() {
        mockDmoValues(new List<Object>{ 'Seg 250', 'New One' });
        SegmentApiMock mock = installMock();
        for (Integer i = 0; i < 260; i++) {
            mock.existing.add(segment('Seg ' + i, 'Seg_' + i));
        }

        sfpegMcnDmoSegmentSync_SVC.SyncResult result = sfpegMcnDmoSegmentSync_SVC.sync(config());

        Assert.areEqual(2, mock.pageCalls);
        Assert.areEqual(new List<String>{ 'Seg 250' }, result.existing);
        Assert.areEqual(1, mock.createdInputs.size());
        Assert.areEqual('New_One', mock.createdInputs[0].developerName);
    }

    @IsTest
    static void respectsMaxCreationsAndIsolatesErrors() {
        mockDmoValues(new List<Object>{ 'A', 'B', 'C', 'D' });
        SegmentApiMock mock = installMock();
        mock.failingDisplayNames.add('A');
        sfpegMcnSegmentSyncConfig__mdt cfg = config();
        cfg.MaxCreationsPerRun__c = 3;

        sfpegMcnDmoSegmentSync_SVC.SyncResult result = sfpegMcnDmoSegmentSync_SVC.sync(cfg);

        Assert.areEqual(1, result.errors.size());
        Assert.isTrue(result.errors.containsKey('A'));
        Assert.areEqual(2, result.created.size());
        Assert.areEqual(new List<String>{ 'D' }, result.postponed);
        Assert.isTrue(result.toString().contains('TestConfig'));
    }

    @IsTest
    static void noDmoValuesSkipsSegmentApi() {
        mockDmoValues(new List<Object>());
        SegmentApiMock mock = installMock();

        sfpegMcnDmoSegmentSync_SVC.SyncResult result = sfpegMcnDmoSegmentSync_SVC.sync(config());

        Assert.isTrue(result.dmoValues.isEmpty());
        Assert.areEqual(0, mock.pageCalls);
    }

    @IsTest
    static void buildsValidUniqueDeveloperNames() {
        Set<String> existing = new Set<String>{ 'vip_customers', 'vip_customers_1' };
        Assert.areEqual('VIP_Customers_2', sfpegMcnDmoSegmentSync_SVC.buildDeveloperName('VIP Customers!', existing));
        Assert.areEqual('Seg_2024_Q1', sfpegMcnDmoSegmentSync_SVC.buildDeveloperName('2024 / Q1', new Set<String>()));
        Assert.areEqual('Seg', sfpegMcnDmoSegmentSync_SVC.buildDeveloperName('***', new Set<String>()));
        String longName = sfpegMcnDmoSegmentSync_SVC.buildDeveloperName('x'.repeat(60), new Set<String>{ 'x'.repeat(40) });
        Assert.areEqual(40, longName.length());
        Assert.isTrue(longName.endsWith('_1'));
    }

    @IsTest
    static void escapesQuotesInSql() {
        String sql = sfpegMcnDmoSegmentSync_SVC.mergeTemplate('WHERE x = \'{segmentValue}\'', config(), 'O\'Brien');
        Assert.areEqual('WHERE x = \'O\'\'Brien\'', sql);
    }

    @IsTest
    static void rejectsInvalidConfig() {
        sfpegMcnSegmentSyncConfig__mdt cfg = config();
        cfg.SegmentNameField__c = 'Name__c; DROP';
        try {
            sfpegMcnDmoSegmentSync_SVC.sync(cfg);
            Assert.fail('Exception expected');
        } catch (sfpegMcnDmoSegmentSync_SVC.SyncException e) {
            Assert.isTrue(e.getMessage().contains('Invalid API name'));
        }

        cfg = config();
        cfg.SegmentSqlTemplate__c = 'SELECT 1';
        try {
            sfpegMcnDmoSegmentSync_SVC.sync(cfg);
            Assert.fail('Exception expected');
        } catch (sfpegMcnDmoSegmentSync_SVC.SyncException e) {
            Assert.isTrue(e.getMessage().contains('{segmentValue}'));
        }
    }

    @IsTest
    static void schedulableAndQueueableRun() {
        mockDmoValues(new List<Object>());
        installMock();

        Test.startTest();
        String jobId = System.schedule('sfpegMcnDmoSegmentSyncTest', '0 0 2 * * ?', new sfpegMcnDmoSegmentSync_SCH());
        new sfpegMcnDmoSegmentSync_SCH(new Set<String>{ 'DoesNotExist' }).execute(null);
        // Unknown config names are silently ignored by the queueable.
        System.enqueueJob(new sfpegMcnDmoSegmentSync_QUE(new List<String>{ 'DoesNotExist', 'Other' }));
        Test.stopTest();

        Assert.isNotNull(jobId);
        Assert.isNull(sfpegMcnDmoSegmentSync_SCH.run(new Set<String>{ 'DoesNotExist' }));
    }

    @IsTest
    static void queueableRequeuesSameConfigWhileValuesRemain() {
        mockDmoValues(new List<Object>{ 'A', 'B', 'C', 'D', 'E' });
        SegmentApiMock mock = installMock();
        mock.failingDisplayNames.add('B');
        installConfigs(2, new List<String>{ 'TestConfig', 'OtherConfig' });

        // Iteration 1: A created, B failed (max 2 reached), C/D/E postponed -> requeue same config.
        new sfpegMcnDmoSegmentSync_QUE(new List<String>{ 'TestConfig', 'OtherConfig' }).execute(null);
        sfpegMcnDmoSegmentSync_QUE next = sfpegMcnDmoSegmentSync_QUE.nextJob;
        Assert.isNotNull(next, 'Requeue expected');
        Assert.areEqual(new List<String>{ 'TestConfig', 'OtherConfig' }, next.configNames);
        Assert.areEqual(2, next.iteration);
        Assert.areEqual(new Set<String>{ 'B' }, next.failedValues);
        Assert.areEqual(1, mock.createdInputs.size());

        // Iteration 2: A existing, B skipped, C/D created, E postponed -> requeue same config.
        mock.existing.add(segment('A', 'A'));
        sfpegMcnDmoSegmentSync_QUE.nextJob = null;
        // Each queueable iteration is a new transaction running the DMO query again.
        mockDmoValues(new List<Object>{ 'A', 'B', 'C', 'D', 'E' });
        next.execute(null);
        next = sfpegMcnDmoSegmentSync_QUE.nextJob;
        Assert.areEqual(3, next.iteration);
        Assert.areEqual('TestConfig', next.configNames[0]);
        Assert.areEqual(3, mock.createdInputs.size());

        // Iteration 3: E created, nothing remaining -> move to next configuration.
        mock.existing.add(segment('C', 'C'));
        mock.existing.add(segment('D', 'D'));
        sfpegMcnDmoSegmentSync_QUE.nextJob = null;
        // Each queueable iteration is a new transaction running the DMO query again.
        mockDmoValues(new List<Object>{ 'A', 'B', 'C', 'D', 'E' });
        next.execute(null);
        next = sfpegMcnDmoSegmentSync_QUE.nextJob;
        Assert.areEqual(4, mock.createdInputs.size());
        Assert.areEqual(new List<String>{ 'OtherConfig' }, next.configNames);
        Assert.areEqual(1, next.iteration);
        Assert.isTrue(next.failedValues.isEmpty());
    }

    @IsTest
    static void queueableStopsWhenAllProcessed() {
        mockDmoValues(new List<Object>{ 'A' });
        installMock();
        installConfigs(5, new List<String>{ 'TestConfig' });

        new sfpegMcnDmoSegmentSync_QUE(new List<String>{ 'TestConfig' }).execute(null);

        Assert.isNull(sfpegMcnDmoSegmentSync_QUE.nextJob, 'No requeue expected');
    }

    @IsTest
    static void queueableStopsAtMaxIterations() {
        mockDmoValues(new List<Object>{ 'A', 'B' });
        installMock();
        installConfigs(1, new List<String>{ 'TestConfig' });

        new sfpegMcnDmoSegmentSync_QUE(
            new List<String>{ 'TestConfig' },
            null,
            sfpegMcnDmoSegmentSync_QUE.MAX_ITERATIONS_PER_CONFIG
        ).execute(null);

        Assert.isNull(sfpegMcnDmoSegmentSync_QUE.nextJob, 'No requeue expected beyond max iterations');
    }

    @IsTest
    static void syncSkipsExcludedValues() {
        mockDmoValues(new List<Object>{ 'A', 'B' });
        SegmentApiMock mock = installMock();

        sfpegMcnDmoSegmentSync_SVC.SyncResult result = sfpegMcnDmoSegmentSync_SVC.sync(config(), new Set<String>{ 'A' });

        Assert.areEqual(new List<String>{ 'A' }, result.skipped);
        Assert.areEqual(1, mock.createdInputs.size());
        Assert.areEqual('B', mock.createdInputs[0].displayName);
        Assert.isFalse(result.hasRemaining());
    }

    /** @description Injects in-memory configurations in place of the custom metadata records. */
    private static void installConfigs(Integer maxCreations, List<String> names) {
        Map<String, sfpegMcnSegmentSyncConfig__mdt> configs = new Map<String, sfpegMcnSegmentSyncConfig__mdt>();
        for (String name : names) {
            sfpegMcnSegmentSyncConfig__mdt cfg = config();
            cfg.DeveloperName = name;
            cfg.MaxCreationsPerRun__c = maxCreations;
            configs.put(name, cfg);
        }
        sfpegMcnDmoSegmentSync_SVC.testConfigs = configs;
    }

    @IsTest
    static void noPublishDatesWithoutSchedule() {
        sfpegMcnSegmentSyncConfig__mdt cfg = config();
        cfg.PublishSchedule__c = null;
        ConnectApi.CdpSegmentInput input = sfpegMcnDmoSegmentSync_SVC.buildSegmentInput(cfg, 'X', 'X', 'X');
        Assert.isNull(input.publishSchedule);
        Assert.isNull(input.publishScheduleStartDateTime);
        Assert.isNull(input.publishScheduleEndDate);
    }

    @IsTest
    static void usesConfiguredPublishDuration() {
        sfpegMcnSegmentSyncConfig__mdt cfg = config();
        cfg.PublishSchedule__c = 'Twelve';
        cfg.PublishScheduleDuration__c = 30;
        ConnectApi.CdpSegmentInput input = sfpegMcnDmoSegmentSync_SVC.buildSegmentInput(cfg, 'X', 'X', 'X');
        Assert.areEqual(ConnectApi.PublishSchedule.Twelve, input.publishSchedule);
        Datetime start = sfpegMcnDmoSegmentSync_SVC.getNextFullHour(Datetime.now());
        Assert.areEqual(start.addDays(30).formatGmt(sfpegMcnDmoSegmentSync_SVC.PUBLISH_DATETIME_FORMAT), input.publishScheduleEndDate);
    }

    @IsTest
    static void computesNextFullHour() {
        Datetime value = Datetime.newInstanceGmt(2026, 11, 20, 23, 15, 42);
        Assert.areEqual(Datetime.newInstanceGmt(2026, 11, 21, 0, 0, 0), sfpegMcnDmoSegmentSync_SVC.getNextFullHour(value));
        value = Datetime.newInstanceGmt(2026, 11, 20, 10, 0, 0);
        Assert.areEqual(Datetime.newInstanceGmt(2026, 11, 20, 11, 0, 0), sfpegMcnDmoSegmentSync_SVC.getNextFullHour(value));
    }

    @IsTest
    static void retriesWithAnotherNameWhenTaken() {
        mockDmoValues(new List<Object>{ 'VIP', 'Gold' });
        SegmentApiMock mock = installMock();
        mock.takenDeveloperNames.addAll(new Set<String>{ 'VIP', 'VIP_1' });
        mock.takenDeveloperNames.addAll(new Set<String>{ 'Gold', 'Gold_1', 'Gold_2', 'Gold_3', 'Gold_4' });

        sfpegMcnDmoSegmentSync_SVC.SyncResult result = sfpegMcnDmoSegmentSync_SVC.sync(config());

        Assert.areEqual(1, mock.createdInputs.size());
        Assert.areEqual('VIP_2', mock.createdInputs[0].developerName);
        Assert.areEqual('VIP', mock.createdInputs[0].displayName);
        Assert.isTrue(result.errors.containsKey('Gold'), 'Gold should fail after max attempts');
    }

    @IsTest
    static void appliesSegmentNameTemplate() {
        mockDmoValues(new List<Object>{ 'Gold', 'Silver' });
        SegmentApiMock mock = installMock();
        // 'Gold' already exists under its templated name, 'Silver' only under its raw value.
        mock.existing.add(segment('EMEA - Gold', 'EMEA_Gold'));
        mock.existing.add(segment('Silver', 'Silver'));
        sfpegMcnSegmentSyncConfig__mdt cfg = config();
        cfg.SegmentNameTemplate__c = 'EMEA - {segmentValue}';
        cfg.SegmentDescription__c = '{segmentName} from {segmentValue}';

        sfpegMcnDmoSegmentSync_SVC.SyncResult result = sfpegMcnDmoSegmentSync_SVC.sync(cfg);

        Assert.areEqual(new List<String>{ 'Gold' }, result.existing);
        Assert.areEqual(1, mock.createdInputs.size());
        ConnectApi.CdpSegmentInput silver = mock.createdInputs[0];
        Assert.areEqual('EMEA - Silver', silver.displayName);
        Assert.areEqual('EMEA_Silver', silver.developerName);
        Assert.areEqual('EMEA - Silver from Silver', silver.description);
        // The SQL keeps using the raw value.
        Assert.isTrue(silver.includeDbt.models[0].sql.contains('= \'Silver\''), silver.includeDbt.models[0].sql);
    }

    @IsTest
    static void rejectsNameTemplateWithoutValue() {
        sfpegMcnSegmentSyncConfig__mdt cfg = config();
        cfg.SegmentNameTemplate__c = 'EMEA segment';
        try {
            sfpegMcnDmoSegmentSync_SVC.sync(cfg);
            Assert.fail('Exception expected');
        } catch (sfpegMcnDmoSegmentSync_SVC.SyncException e) {
            Assert.isTrue(e.getMessage().contains('name template'), e.getMessage());
        }
    }

    @IsTest
    static void publishesCreatedSegmentsOnceActive() {
        mockDmoValues(new List<Object>{ 'A', 'B' });
        SegmentApiMock mock = installMock();
        installConfigs(5, new List<String>{ 'TestConfig' });
        sfpegMcnDmoSegmentSync_SVC.testConfigs.get('TestConfig').PublishOnCreation__c = true;

        // Sync: A and B created -> publication job enqueued with a delay.
        new sfpegMcnDmoSegmentSync_QUE(new List<String>{ 'TestConfig' }).execute(null);
        sfpegMcnDmoSegmentSync_QUE next = sfpegMcnDmoSegmentSync_QUE.nextJob;
        Assert.isNotNull(next, 'Publication job expected');
        Assert.isTrue(next.configNames.isEmpty());
        Assert.areEqual(new List<String>{ 'ID_A', 'ID_B' }, next.pendingPublishIds);
        Assert.areEqual(sfpegMcnDmoSegmentSync_QUE.PUBLISH_DELAY_MINUTES, sfpegMcnDmoSegmentSync_QUE.nextDelay);

        // Attempt 1: A active (published), B still processing -> retry B.
        mock.statusById.put('ID_A', 'ACTIVE');
        sfpegMcnDmoSegmentSync_QUE.nextJob = null;
        next.execute(null);
        Assert.areEqual(new List<String>{ 'ID_A' }, mock.publishedIds);
        next = sfpegMcnDmoSegmentSync_QUE.nextJob;
        Assert.areEqual(new List<String>{ 'ID_B' }, next.pendingPublishIds);
        Assert.areEqual(2, next.publishAttempt);

        // Attempt 2: B active -> published, no further job.
        mock.statusById.put('ID_B', 'ACTIVE');
        sfpegMcnDmoSegmentSync_QUE.nextJob = null;
        next.execute(null);
        Assert.areEqual(new List<String>{ 'ID_A', 'ID_B' }, mock.publishedIds);
        Assert.isNull(sfpegMcnDmoSegmentSync_QUE.nextJob);
    }

    @IsTest
    static void doesNotPublishWhenNotRequested() {
        mockDmoValues(new List<Object>{ 'A' });
        SegmentApiMock mock = installMock();
        installConfigs(5, new List<String>{ 'TestConfig' });

        new sfpegMcnDmoSegmentSync_QUE(new List<String>{ 'TestConfig' }).execute(null);

        Assert.areEqual(1, mock.createdInputs.size());
        Assert.isNull(sfpegMcnDmoSegmentSync_QUE.nextJob, 'No publication job expected');
    }

    @IsTest
    static void stopsPublicationAfterMaxAttempts() {
        SegmentApiMock mock = installMock();
        mock.statusById.put('ID_X', 'PROCESSING');

        new sfpegMcnDmoSegmentSync_QUE(null, null, 1, new List<String>{ 'ID_X' }, sfpegMcnDmoSegmentSync_QUE.MAX_PUBLISH_ATTEMPTS).execute(null);

        Assert.isTrue(mock.publishedIds.isEmpty());
        Assert.isNull(sfpegMcnDmoSegmentSync_QUE.nextJob, 'No retry expected beyond max attempts');
    }

    @IsTest
    static void publicationIgnoresFailedAndUnknownSegments() {
        SegmentApiMock mock = installMock();
        mock.statusById.put('ID_KO', 'ACTIVE');
        mock.publishErrorIds.add('ID_KO');
        mock.statusById.put('ID_ERR', 'ERROR');
        mock.statusById.put('ID_OK', 'ACTIVE');

        List<String> pending = sfpegMcnDmoSegmentSync_SVC.publishActiveSegments(
            new List<String>{ 'ID_KO', 'ID_ERR', 'ID_UNKNOWN', 'ID_OK' }
        );

        Assert.isTrue(pending.isEmpty());
        Assert.areEqual(new List<String>{ 'ID_OK' }, mock.publishedIds);
        Assert.isTrue(sfpegMcnDmoSegmentSync_SVC.publishActiveSegments(null).isEmpty());
    }
}
