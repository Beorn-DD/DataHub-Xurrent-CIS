# Input bindings are passed in via param block.
param($Timer)

# Get the current universal time in the default string format.
$currentUTCtime = (Get-Date).ToUniversalTime()

# The 'IsPastDue' property is 'true' when the current function invocation is later than scheduled.
if ($Timer.IsPastDue) {
    Write-Host "PowerShell timer is running late!"
}

$DataHub_Table = "CMDB_EndUser_Computer"
$DataHub_URL = "https://hub.muellergroup.aspera.com/v1/resultDatabase/table/$DataHub_Table"
$DataHub_KEY = $env:DataHub_API_Key
$PageSize = 1000 # Anzahl der Datensätze pro Seite
$csvFilePath = "DataHub_$DataHub_Table.csv"

$header = @{
    "ApiKey" = $DataHub_KEY
    "Accept" = "application/json"
}

$allRecords = @()

try {
    $currentPage = 1
    $hasMorePages = $true
    $pagedUrl = "$DataHub_URL/paged?page=$currentPage&page_size=$PageSize"

    Write-Output "$(Get-Date) Gathering Data from DataHub table $DataHub_Table"

    while ($hasMorePages) {

        # Abrufen der Daten von der aktuellen Seite
        $response = Invoke-WebRequest -Uri $pagedUrl -Headers $header -Method Get
        $jsonData = $response.Content | ConvertFrom-Json
        $next_page = $jsonData.pagination.next

        Write-Output "$(Get-Date) Received Response for Page $currentPage "

        # Extrahieren der Datensätze
        $records = $jsonData.records

        # Aggregieren der Seiten
        $allRecords += $records
        $currentPage++

        # Check auf Folgeseite
        if ($null -eq $next_page) {
            $hasMorePages = $false
        } else {
            $pagedUrl = "https://hub.muellergroup.aspera.com/$next_page"
        }
    }

    # Ausgeben der Anzahl Einträge aus dem DataHub
    $num_records = $allRecords.Count
    Write-Output "$(Get-Date) Received Records: $num_records"

    # Überprüfen, ob Datensätze leer sind
    if ($allRecords.Count -eq 0) {
        throw "No records found in the response."
    }

    # Konvertieren der Datensätze in CSV-Format
    $csvData = @()
    $columns = $jsonData.columns.name
    foreach ($record in $allRecords) {
        $csvObject = [pscustomobject]@{}
        foreach ($column in $columns) {
            $csvObject | Add-Member -MemberType NoteProperty -Name $column -Value $record.$column
        }
        $csvData += $csvObject
    }

    # Exportieren in eine CSV-Datei ohne Anführungszeichen
    $csvData | Export-Csv -Path $csvFilePath -NoTypeInformation -UseQuotes AsNeeded

    Write-Output "$(Get-Date) CSV file created successfully at $csvFilePath"

} catch {
    Write-Error "$(Get-Date) An error occurred: $_"
    Write-Error "$(Get-Date) Status Code: $($_.Exception.Response.StatusCode)"
    Write-Error "$(Get-Date) Status Description: $($_.Exception.Response.StatusDescription)"
}

# Request Access Token from Xurrent using OAuth2 and convert it from JSON
# Define the OAuth2 parameters
$clientId = $env:Xurrent_Client_Id
$clientSecret = $env:Xurrent_Client_Secret
$tokenUrl = "https://oauth.xurrent.com/token"
$importUrl = "https://api.xurrent.com/v1/import"

# Create the body for the token request
$body = @{
    grant_type = "client_credentials"
    client_id = $clientId
    client_secret = $clientSecret
}

try {
    # Make the token request
    Write-Output "$(Get-Date) Authenticate at $tokenUrl"
    
    $response = Invoke-RestMethod -Method Post -Uri $tokenUrl -ContentType "application/x-www-form-urlencoded" -Body $body
    # Extract the bearer token from the response
    $bearerToken = $response.access_token
} catch {
    Write-Error "$(Get-Date) Failed to obtain bearer token: $_"
    exit
}

# Create the headers for the import request
$ImportHeaders = @{
    Authorization = "Bearer $bearerToken"
    "X-4me-Account" = "mueller-coreit"
    "Content-Type" = "multipart/form-data"
}

# Create the body for the import request
$importBody = @{
    file = Get-Item -Path $csvFilePath
    type = "cis"
}

try {
    # Make the import request
    $importResponse = Invoke-RestMethod -Method Post -Uri $importUrl -Headers $ImportHeaders -Form $importBody
    Write-Output "$(Get-Date) Import job initiated. Token: $importResponse"
} catch {
    Write-Error "$(Get-Date) Failed to import file: $_"
}


try {
    # Löschen der CSV-Datei
    Remove-Item -Path $csvFilePath -Force
    Write-Output "$(Get-Date) CSV file deleted successfully."
} catch {
    Write-Error "$(Get-Date) Failed to delete file: $_"
}

# Extract the import token from the response
$importToken = $importResponse.token

# Define the URL for checking the import status
$statusUrl = "$importUrl/$importToken"

# Initialize the status variable
$status = ""

# Loop to check the status every 10 Sec until it is "done"
while ($status -ne "done" -and $status -ne "error") {
    try {
        # Make the status request
        $statusResponse = Invoke-RestMethod -Method Get -Uri $statusUrl -Headers $ImportHeaders
        $status = $statusResponse.state
        Write-Output "$(Get-Date) Current Status: $status"
        
        # Wait for 10 seconds before the next check
        Start-Sleep -Seconds 10
    } catch {
        Write-Error "$(Get-Date) Failed to check import status: $_"
        exit
    }
}

$Results = $statusResponse.results
$LogFile = $statusResponse.logfile

Write-Output "$(Get-Date) Import process completed with status: $status"
Write-Output "$(Get-Date) Results are: $Results"
Write-Output "$(Get-Date) LogFile: $LogFile"