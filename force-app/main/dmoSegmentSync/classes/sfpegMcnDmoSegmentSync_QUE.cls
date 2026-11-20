/***
* @description  Asynchronous job synchronising Data360 segments, one configuration per job
*               (each configuration gets its own governor limits), chaining itself for the remaining ones.
*               Implements Database.AllowsCallouts as the Data 360 SQL queries and segment APIs may
*               require it.
*               Part of the PEG_MCN package.
* @author       P-E GROS
* @date         Nov. 2026
* @see          sfpegMcnDmoSegmentSync_TST
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

public with sharing class sfpegMcnDmoSegmentSync_QUE implements Queueable, Database.AllowsCallouts {
    /** @description Safety limit on the number of iterations for a same configuration. */
    @TestVisible
    private static final Integer MAX_ITERATIONS_PER_CONFIG = 100;
    /** @description Max number of publication attempts (waiting for created segments to become active). */
    @TestVisible
    private static final Integer MAX_PUBLISH_ATTEMPTS = 10;
    /** @description Delay (in minutes) before each publication attempt. */
    @TestVisible
    private static final Integer PUBLISH_DELAY_MINUTES = 1;

    @TestVisible
    private final List<String> configNames;
    /** @description Values whose creation failed in previous iterations of the current configuration. */
    @TestVisible
    private final Set<String> failedValues;
    /** @description Iteration number on the current (first) configuration (starting at 1). */
    @TestVisible
    private final Integer iteration;
    /** @description marketSegmentId of the created segments still to be published. */
    @TestVisible
    private final List<String> pendingPublishIds;
    /** @description Publication attempt number (once all configurations are processed, starting at 1). */
    @TestVisible
    private final Integer publishAttempt;

    /** @description Set to the job which would be enqueued next (for tests, as chaining is disabled in tests). */
    @TestVisible
    private static sfpegMcnDmoSegmentSync_QUE nextJob;
    /** @description Delay (in minutes) of the next job (for tests). */
    @TestVisible
    private static Integer nextDelay;

    /**
     * @param configNames DeveloperNames of the sfpegMcnSegmentSyncConfig__mdt records still to process
     */
    public sfpegMcnDmoSegmentSync_QUE(List<String> configNames) {
        this(configNames, null, 1, null, 1);
    }

    @TestVisible
    private sfpegMcnDmoSegmentSync_QUE(List<String> configNames, Set<String> failedValues, Integer iteration) {
        this(configNames, failedValues, iteration, null, 1);
    }

    /**
     * @param configNames DeveloperNames of the sfpegMcnSegmentSyncConfig__mdt records still to process
     *                    (the first one being the one to process in this job)
     * @param failedValues values of the first configuration already failed in previous iterations
     * @param iteration iteration number on the first configuration
     * @param pendingPublishIds marketSegmentId of the created segments still to publish
     * @param publishAttempt publication attempt number
     */
    @TestVisible
    private sfpegMcnDmoSegmentSync_QUE(
        List<String> configNames,
        Set<String> failedValues,
        Integer iteration,
        List<String> pendingPublishIds,
        Integer publishAttempt
    ) {
        System.debug(LoggingLevel.FINE, 'sfpegMcnDmoSegmentSync_QUE: constructor with configNames ' + configNames + ' / failedValues ' + failedValues + ' / iteration ' + iteration + ' / pendingPublishIds ' + pendingPublishIds + ' / publishAttempt ' + publishAttempt);
        this.configNames = configNames == null ? new List<String>() : new List<String>(configNames);
        this.failedValues = failedValues == null ? new Set<String>() : new Set<String>(failedValues);
        this.iteration = iteration == null || iteration < 1 ? 1 : iteration;
        this.pendingPublishIds = pendingPublishIds == null ? new List<String>() : new List<String>(pendingPublishIds);
        this.publishAttempt = publishAttempt == null || publishAttempt < 1 ? 1 : publishAttempt;
    }

    public void execute(QueueableContext context) {
        System.debug('sfpegMcnDmoSegmentSync_QUE.execute: START with job ' + context?.getJobId() + ' / configNames ' + configNames + ' / iteration ' + iteration + ' / failedValues ' + failedValues + ' / pendingPublishIds ' + pendingPublishIds + ' / publishAttempt ' + publishAttempt);
        if (configNames.isEmpty()) {
            executePublication();
            return;
        }

        String current = configNames[0];
        List<String> otherConfigs = new List<String>(configNames);
        otherConfigs.remove(0);
        List<String> toPublish = new List<String>(pendingPublishIds);
        System.debug('sfpegMcnDmoSegmentSync_QUE.execute: processing configuration ' + current + ' iteration ' + iteration + ' (' + otherConfigs.size() + ' other configuration(s) remaining)');

        sfpegMcnDmoSegmentSync_QUE next = null;
        try {
            List<sfpegMcnSegmentSyncConfig__mdt> configs = sfpegMcnDmoSegmentSync_SVC.getActiveConfigs(new Set<String>{ current });
            if (!configs.isEmpty()) {
                sfpegMcnDmoSegmentSync_SVC.SyncResult result = sfpegMcnDmoSegmentSync_SVC.sync(configs[0], failedValues);
                System.debug('sfpegMcnDmoSegmentSync_QUE.execute: configuration processed ' + result);
                if (configs[0].PublishOnCreation__c && !result.createdIds.isEmpty()) {
                    System.debug('sfpegMcnDmoSegmentSync_QUE.execute: registering created segments for publication ' + result.createdIds);
                    toPublish.addAll(result.createdIds);
                }
                if (result.hasRemaining()) {
                    if (iteration < MAX_ITERATIONS_PER_CONFIG) {
                        Set<String> allFailed = new Set<String>(failedValues);
                        allFailed.addAll(result.errors.keySet());
                        System.debug('sfpegMcnDmoSegmentSync_QUE.execute: ' + result.postponed.size() + ' value(s) remaining for ' + current + ', requeueing same configuration');
                        next = new sfpegMcnDmoSegmentSync_QUE(configNames, allFailed, iteration + 1, toPublish, 1);
                    }
                    else {
                        System.debug(LoggingLevel.ERROR, 'sfpegMcnDmoSegmentSync_QUE.execute: max iterations (' + MAX_ITERATIONS_PER_CONFIG + ') reached for ' + current + ', ' + result.postponed.size() + ' value(s) left for next scheduled run');
                    }
                }
            }
            else {
                System.debug(LoggingLevel.WARN, 'sfpegMcnDmoSegmentSync_QUE.execute: configuration not found or inactive ' + current);
            }
        } catch (Exception e) {
            System.debug(
                LoggingLevel.ERROR,
                'sfpegMcnDmoSegmentSync_QUE.execute: configuration ' + current + ' failed: ' + e.getTypeName() + ': ' + e.getMessage() +
                '\n' + e.getStackTraceString()
            );
        }

        Integer delay = 0;
        if (next == null && !otherConfigs.isEmpty()) {
            System.debug('sfpegMcnDmoSegmentSync_QUE.execute: configuration ' + current + ' completed, moving to next configuration ' + otherConfigs[0]);
            next = new sfpegMcnDmoSegmentSync_QUE(otherConfigs, null, 1, toPublish, 1);
        }
        if (next == null && !toPublish.isEmpty()) {
            System.debug('sfpegMcnDmoSegmentSync_QUE.execute: all configurations processed, ' + toPublish.size() + ' segment(s) to publish once active');
            next = new sfpegMcnDmoSegmentSync_QUE(null, null, 1, toPublish, 1);
            delay = PUBLISH_DELAY_MINUTES;
        }
        enqueueNext(next, delay);
    }

    /**
     * @description Publication phase: publishes the created segments which are active, and
     * requeues itself (with a delay) for the ones still being processed.
     */
    private void executePublication() {
        System.debug('sfpegMcnDmoSegmentSync_QUE.executePublication: START attempt ' + publishAttempt + ' for ' + pendingPublishIds);
        if (pendingPublishIds.isEmpty()) {
            System.debug(LoggingLevel.WARN, 'sfpegMcnDmoSegmentSync_QUE.executePublication: END with nothing to process');
            return;
        }
        List<String> stillPending = sfpegMcnDmoSegmentSync_SVC.publishActiveSegments(pendingPublishIds);
        sfpegMcnDmoSegmentSync_QUE next = null;
        if (!stillPending.isEmpty()) {
            if (publishAttempt < MAX_PUBLISH_ATTEMPTS) {
                System.debug('sfpegMcnDmoSegmentSync_QUE.executePublication: ' + stillPending.size() + ' segment(s) not active yet, retrying in ' + PUBLISH_DELAY_MINUTES + ' minute(s)');
                next = new sfpegMcnDmoSegmentSync_QUE(null, null, 1, stillPending, publishAttempt + 1);
            }
            else {
                System.debug(LoggingLevel.ERROR, 'sfpegMcnDmoSegmentSync_QUE.executePublication: max publication attempts (' + MAX_PUBLISH_ATTEMPTS + ') reached, segments not published ' + stillPending);
            }
        }
        enqueueNext(next, PUBLISH_DELAY_MINUTES);
        System.debug('sfpegMcnDmoSegmentSync_QUE.executePublication: END');
    }

    /** @description Enqueues the next job (if any) with an optional delay in minutes. */
    private static void enqueueNext(sfpegMcnDmoSegmentSync_QUE next, Integer delay) {
        if (next == null) {
            System.debug('sfpegMcnDmoSegmentSync_QUE.execute: END with all configurations processed');
            return;
        }
        nextJob = next;
        nextDelay = delay;
        // Queueable chaining is not allowed in test context.
        if (Test.isRunningTest()) {
            System.debug('sfpegMcnDmoSegmentSync_QUE.execute: END in test context (next job not enqueued) for ' + next.configNames + ' iteration ' + next.iteration + ' / publication ' + next.pendingPublishIds + ' with delay ' + delay);
            return;
        }
        Id nextJobId = delay > 0 ? System.enqueueJob(next, delay) : System.enqueueJob(next);
        System.debug('sfpegMcnDmoSegmentSync_QUE.execute: END with next job ' + nextJobId + ' enqueued for ' + next.configNames + ' iteration ' + next.iteration + ' / publication ' + next.pendingPublishIds + ' with delay ' + delay);
    }
}
