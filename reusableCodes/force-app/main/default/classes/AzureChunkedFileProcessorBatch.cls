/**
 * @Author      : Chethan Kumar N C
 * @CreatedDate : 2025-06-02
 * @Description : Batch class to fetch file from Azure in Chunks.
 * @TestClass   : PrintJobCSVGenerationBatchTest
 */
global class AzureChunkedFileProcessorBatch implements Database.Batchable<sObject>, Database.Stateful, Database.AllowsCallouts {
    
    private String storageName;
    private String containerName;
    private String storageKey;
    private String fileName;
    private Integer startRange = 0;
    private Boolean batchFail = false;
    private String leftover = '';
    private List<String> headerFields = new List<String>();
    private Boolean headerParsed = false;
    private List<List<String>> fetchedCsvRows = new List<List<String>>();
    private Integer totalSize = 0;
    private Integer totalBytesFetched = 0;
    private String sasToken;
    private Integer currentChunkStart = 0;
    private Integer chunkSize = 128 * 1024; // 128KB chunks
    private List<sObject> dummyRecords = new List<sObject>(); // For batch processing
    private Integer epcColumnIndex = -1;
    private List<String> convertedEpcValues = new List<String>();

    global AzureChunkedFileProcessorBatch(String fileName) {
        Decathlon_Azure_Blob_Storage_Detail__c decAzBlobStorgDetail = Decathlon_Azure_Blob_Storage_Detail__c.getInstance();       
        this.storageName = decAzBlobStorgDetail.StorageName__c;
        this.containerName = decAzBlobStorgDetail.PrintJob_Container_Name__c;
        this.storageKey = decAzBlobStorgDetail.StorageKey__c;
        this.fileName = fileName;
    }

    global Iterable<sObject> start(Database.BatchableContext bc) {
        // Get file size first
        String account = storageName;
        String encodedFileName = EncodingUtil.urlEncode(fileName, 'UTF-8');
        String endpoint = 'https://' + account + '.file.core.windows.net/' + containerName + '/' + encodedFileName;
        
        // Generate SAS token once
        this.sasToken = generateSasToken(account, containerName, fileName, storageKey);
        String fileUrlWithSas = endpoint + '?' + sasToken;

        totalSize = getFileSize(fileUrlWithSas);
        System.debug('Total file size: ' + totalSize + ' bytes.');

        // Create dummy records for batch processing (one per chunk)
        List<sObject> records = new List<sObject>();
        Integer numChunks = (Integer)Math.ceil((Double)totalSize / chunkSize);
        
        for (Integer i = 0; i < numChunks; i++) {
            records.add(new Account(Name = 'Chunk_' + i)); // Using Account as dummy object
        }
        
        System.debug('Created ' + records.size() + ' chunks for processing');
        return records;
    }
    
    global void execute(Database.BatchableContext bc, List<sObject> scope) {
        System.debug('Processing ' + scope.size() + ' chunk(s)');
        if (scope.isEmpty()) return;

        try {
            // Calculate chunk boundaries
            Integer chunkIndex = Integer.valueOf(((Account)scope[0]).Name.replace('Chunk_', ''));
            Integer chunkStart = chunkIndex * chunkSize;
            Integer chunkEnd = Math.min(chunkStart + chunkSize - 1, totalSize - 1);

            System.debug('Processing chunk: start=' + chunkStart + ', end=' + chunkEnd);

            // Fetch chunk from Azure
            String csvChunk = fetchRowsFromAzure(chunkStart, chunkEnd);
            totalBytesFetched += csvChunk.length();

            // Process the chunk
            processCsvChunk(csvChunk);

        } catch (Exception e) {
            System.debug('Error processing chunk: ' + e.getMessage());
            batchFail = true;
        }
    }
    
    global void finish(Database.BatchableContext bc) {
        System.debug('Batch processing complete!');
        System.debug('Total bytes fetched: ' + totalBytesFetched + ' of ' + totalSize);
        System.debug('Total rows processed: ' + fetchedCsvRows.size());
        
        if (batchFail) {
            System.debug('Batch processing failed');
        } else {
            System.debug('Batch processing completed successfully');
        }

        if (!convertedEpcValues.isEmpty()) {
            List<String> firstTen = new List<String>();
            Integer z=50;
            for (Integer i = 0; i < z; i++) {
                firstTen.add(convertedEpcValues[i]);
            }
            System.debug('First 10 EPCs: ' + String.valueOf(firstTen));
        }
        System.debug('Total \"Converted_ EPC\" values collected: ' + convertedEpcValues.size());
    }

    private void processCsvChunk(String csvChunk) {
        // Combine with leftover from previous chunk
        String processableContent = leftover + csvChunk;
        leftover = '';

        // Find complete lines (ending with newline)
        Integer startPos = 0;
        Integer newlinePos;
        
        while ((newlinePos = processableContent.indexOf('\n', startPos)) != -1) {
            String line = processableContent.substring(startPos, newlinePos).trim();
            if (String.isNotBlank(line)) {
                if (!headerParsed) {
                    headerFields = parseCsvLineUltraEfficient(line);
                    String targetHeader = 'Converted_ EPC'.replaceAll('[^a-zA-Z0-9]', '').toLowerCase();
                    System.debug('Normalized target header: ' + targetHeader);
                    for (Integer i = 0; i < headerFields.size(); i++) {
                        String currentHeader = headerFields[i].replaceAll('[^a-zA-Z0-9]', '').toLowerCase();
                        System.debug('Header index ' + i + ': raw="' + headerFields[i] + '", normalized="' + currentHeader + '"');
                        if (currentHeader == targetHeader) {
                            epcColumnIndex = i;
                            break;
                        }
                    }
                    headerParsed = true;
                    System.debug('CSV Header: ' + headerFields);
                    System.debug('Found \"Converted_ EPC\" column at index: ' + epcColumnIndex);
                } else {
                    List<String> rowFields = parseCsvLineUltraEfficient(line);
                    fetchedCsvRows.add(rowFields);

                    // If the EPC column was found, store the value
                    if (epcColumnIndex != -1 && epcColumnIndex < rowFields.size()) {
                        convertedEpcValues.add(rowFields[epcColumnIndex]);
                    }
                }
            }
            startPos = newlinePos + 1;
        }
        
        // Handle leftover (incomplete line at the end)
        if (startPos < processableContent.length()) {
            leftover = processableContent.substring(startPos);
        }
    }

    // Ultra-efficient CSV line parser - minimal CPU usage
    private List<String> parseCsvLineUltraEfficient(String line) {
        // For most CSV files, simple split works fine
        // Only handle quotes if absolutely necessary
        if (!line.contains('"')) {
            return line.split(',');
        }
        
        // If quotes are present, use a very minimal approach
        // Replace quoted content temporarily to avoid complex parsing
        String processedLine = line;
        
        // Simple approach: split by semicolon and clean up quotes
        List<String> fields = processedLine.split(',');
        List<String> cleanedFields = new List<String>();
        
        for (String field : fields) {
            // Remove surrounding quotes if present
            String cleanedField = field.trim();
            if (cleanedField.startsWith('"') && cleanedField.endsWith('"')) {
                cleanedField = cleanedField.substring(1, cleanedField.length() - 1);
            }
            cleanedFields.add(cleanedField);
        }
        
        return cleanedFields;
    }

    // Helper method to generate SAS token for Azure File Storage
    private String generateSasToken(String account, String containerName, String fileName, String storageKey) {
        String encodedFileName = EncodingUtil.urlEncode(fileName, 'UTF-8');
        DateTime timestamp = Datetime.now().addMinutes(5);
        String reqdate = timestamp.formatGMT('yyyy-MM-dd\'T\'HH:mm:ss\'Z\'');        
        String spe = 'r';
        String st = '';
        String se = reqdate;
        String res = '/file/' + account + '/' + containerName + '/' + fileName;
        String si = '';
        String sip = '';
        String spr = '';
        String sr = 'f';
        String sv = '2017-11-09';
        String rscc = '';
        String rscd = '';
        String rsce = '';
        String rscl = '';
        String rsct = '';
        
        String sts = spe + '\n'  +
            st + '\n' +
            se + '\n' +
            res + '\n' +
            si + '\n' +
            sip + '\n' +
            spr + '\n'+
            sv + '\n' +
            rscc + '\n' +
            rscd + '\n' +
            rsce + '\n' +
            rscl + '\n' +
            rsct;
        
        Blob data = Crypto.generateMac('HmacSHA256', Blob.valueOf(sts), EncodingUtil.base64Decode(storageKey));
        String sas = EncodingUtil.base64Encode(data);
        sas = EncodingUtil.urlEncode(sas, 'UTF-8');
        String sasToken = 'sv=' + sv + '&se=' + se + '&sr=' + sr + '&sp=' + spe + '&sig=' + sas;
        return sasToken;
    }

    // Helper method to make callout
    private String fetchRowsFromAzure(Integer startByte, Integer endByte) {
        String account = storageName;
        String encodedFileName = EncodingUtil.urlEncode(fileName, 'UTF-8');
        String endpoint = 'https://' + account + '.file.core.windows.net/' + containerName + '/' + encodedFileName;
        String fullUrl = endpoint + '?' + sasToken;

        System.debug('Making callout to Azure File Storage:');
        System.debug('URL: ' + fullUrl);
        System.debug('Range: bytes=' + String.valueOf(startByte) + '-' + String.valueOf(endByte));

        HttpRequest req = new HttpRequest();
        req.setEndpoint(fullUrl);
        req.setMethod('GET');
        req.setHeader('Range', 'bytes=' + String.valueOf(startByte) + '-' + String.valueOf(endByte));
        req.setHeader('x-ms-version', '2020-10-02');

        Http http = new Http();
        try {
            HttpResponse res = http.send(req);
            System.debug('Azure response status: ' + res.getStatusCode());
            
            if (res.getStatusCode() == 206 || res.getStatusCode() == 200) {
                String responseBody = res.getBody();
                System.debug('Response body length: ' + responseBody.length());
                return responseBody;
            } else {
                System.debug('Azure error response body: ' + res.getBody());
                throw new CalloutException('Failed to fetch from Azure File Storage. Status: ' + res.getStatus() + ', Body: ' + res.getBody());
            }
        } catch (Exception e) {
            System.debug('HTTP callout exception: ' + e.getMessage());
            throw new CalloutException('HTTP callout to Azure File Storage failed: ' + e.getMessage());
        }
    }

    private static Integer getFileSize(String fileUrl) {
        HttpRequest req = new HttpRequest();
        req.setMethod('HEAD');
        req.setEndpoint(fileUrl);
        req.setHeader('x-ms-version', '2020-10-02');
        
        Http http = new Http();
        HttpResponse res = http.send(req);
        
        if (res.getStatusCode() == 200) {
            return Integer.valueOf(res.getHeader('Content-Length'));
        }
        throw new CalloutException('Failed to get file size: ' + res.getBody());
    }
}