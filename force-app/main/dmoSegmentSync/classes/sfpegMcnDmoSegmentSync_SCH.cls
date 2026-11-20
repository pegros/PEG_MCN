/***
* @description  Schedulable entry point of the DMO to Data360 segment synchronisation.
*               It enqueues a sfpegMcnDmoSegmentSync_QUE job processing the active sfpegMcnSegmentSyncConfig__mdt
*               records (all of them, or only the ones listed in the constructor).
*
*               Example (every day at 2 AM):
*                   System.schedule('DMO Segment Sync', '0 0 2 * * ?', new sfpegMcnDmoSegmentSync_SCH());
*               Example (hourly, single config):
*                   System.schedule('DMO Segment Sync - X', '0 0 * * * ?',
*                   new sfpegMcnDmoSegmentSync_SCH(new Set<String>{ 'MyConfig' }));
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

public with sharing class sfpegMcnDmoSegmentSync_SCH implements Schedulable {
    @TestVisible
    private final Set<String> configNames;

    /** @description Processes all active configurations. */
    public sfpegMcnDmoSegmentSync_SCH() {
        this(null);
    }

    /** @description Processes only the listed active configurations (null/empty = all). */
    public sfpegMcnDmoSegmentSync_SCH(Set<String> configNames) {
        System.debug(LoggingLevel.FINE, 'sfpegMcnDmoSegmentSync_SCH: constructor with configNames ' + configNames);
        this.configNames = configNames;
    }

    public void execute(SchedulableContext context) {
        System.debug('sfpegMcnDmoSegmentSync_SCH.execute: START with trigger ' + context?.getTriggerId() + ' / configNames ' + configNames);
        Id jobId = run(configNames);
        System.debug('sfpegMcnDmoSegmentSync_SCH.execute: END with queued job ' + jobId);
    }

    /**
     * @description Enqueues the synchronisation job (also usable for on-demand runs).
     * @return the queued job Id (null if there is no active configuration)
     */
    public static Id run(Set<String> configNames) {
        System.debug('sfpegMcnDmoSegmentSync_SCH.run: START with configNames ' + configNames);
        List<String> names = new List<String>();
        for (sfpegMcnSegmentSyncConfig__mdt config : sfpegMcnDmoSegmentSync_SVC.getActiveConfigs(configNames)) {
            names.add(config.DeveloperName);
        }
        names.sort();
        if (names.isEmpty()) {
            System.debug(LoggingLevel.WARN, 'sfpegMcnDmoSegmentSync_SCH.run: END with no active configuration to process');
            return null;
        }
        System.debug('sfpegMcnDmoSegmentSync_SCH.run: enqueueing job for configurations ' + names);
        Id jobId = System.enqueueJob(new sfpegMcnDmoSegmentSync_QUE(names));
        System.debug('sfpegMcnDmoSegmentSync_SCH.run: END with queued job ' + jobId);
        return jobId;
    }
}
