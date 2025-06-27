import { LightningElement,track } from 'lwc';

export default class AzureUploadLwc extends LightningElement {
    file;
    fileName;
    uploadedFileUrl;
    @track isLoading = false; // Spinner toggle

    containerName = 'Your container Name';
    sasToken = 'SAS Token Generated from Azure';
    accountName = 'Your Account Name';

    handleFileChange(event) {
        const files = event.target.files;
        if (files.length > 0) {
            this.file = files[0];
            this.fileName = this.file.name;
        }
    }

    async uploadFile() {
        if (!this.file) {
            alert('Please select a file to upload.');
            return;
        }
        this.isLoading = true; // Start spinner
        const uploadUrl = `https://${this.accountName}.blob.core.windows.net/${this.containerName}/${encodeURIComponent(this.fileName)}?${this.sasToken}`;

        try {
            const response = await fetch(uploadUrl, {
                method: 'PUT',
                headers: {
                    'x-ms-blob-type': 'BlockBlob',
                    'Content-Type': this.file.type
                },
                body: this.file
            });

            if (response.ok) {
                this.uploadedFileUrl = uploadUrl;
                alert('✅ File uploaded successfully!');
                // console.log('Uploaded File URL:', uploadUrl);
            } else {
                const errorText = await response.text();
                // console.error('❌ Upload failed:', errorText);
                alert('❌ Upload failed: ' + errorText);
            }
        } catch (error) {
            // console.error('❌ Upload error:', error);
            alert('❌ Upload error: ' + error.message);
        }
        finally {
            this.isLoading = false; 
        }
    }

    downloadFile() {
        if (this.uploadedFileUrl) {
            window.open(this.uploadedFileUrl, '_blank');
        } else {
            alert('⚠️ No file uploaded yet.');
        }
    }
}