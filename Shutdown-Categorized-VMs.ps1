#Certificate information to call Nutanix Prism API
add-type @"
using System.Net;
using System.Security.Cryptography.X509Certificates;
public class TrustAllCertsPolicy : ICertificatePolicy {
    public bool CheckValidationResult(
    ServicePoint srvPoint, X509Certificate certificate,
    WebRequest request, int certificateProblem) {
        return true;
    }
}
"@
[System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllCertsPolicy

# Forcing PoSH to use TLS1.2 as it defaults to 1.0 and Prism requires 1.2.
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# Add Nutanix PoSH Cmdlets
Add-PsSnapin NutanixCmdletsPSSnapin

# Check to see if secure credential file exists. If not, prompts for credentials and creates file.
$CredPath = "C:\SecureString\SecureCredentials.xml"

# Currently a problem but I need to debug why this throws an error
<# $CredPathExists = [System.IO.File]::Exists($CredPath)

if ($CredPathExists -eq $false) {
  GET-CREDENTIAL –Credential (Get-Credential) | EXPORT-CLIXML "$CredPath"
} #>

# Run at the start of each script to import the credentials
$Credentials = IMPORT-CLIXML "$CredPath"
$RESTAPIUser = $Credentials.UserName
$RESTAPIPassword = $Credentials.GetNetworkCredential().Password

# Nutanix Prism REST API Connection information
$cluster = "prism.redacted.com"
$Uri = "https://$($cluster):9440/api/nutanix/v3/category/query"
$Header = @{
"Authorization" = "Basic "+[System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($RESTAPIUser+":"+$RESTAPIPassword ))}

# Prism category and value for the category you wish to list.
$categoryvalue = "PROD"

# JSON body being passed to Prism API. Looking for all VM's belonging to the PS category in Prism.
$json =@"
{
    "usage_type": "APPLIED_TO",
    "group_member_offset": 0,
    "group_member_count": 100,
    "category_filter": {
      "type": "CATEGORIES_MATCH_ANY",
      "params": {
        "$categoryvalue": ["$categoryvalue"]    
  },
  "kind_list": ["vm"]
    },
    "api_version": "3.1.0"
  }
"@

#API Call passing authentication via headers and post request for category query via the body
$apicall = Invoke-RestMethod -Method Post -Uri $Uri -Headers $Header -Body $json -ContentType "application/json"

#API call returns a list of objects including VM name, uuid etc. UUID is required for the next phase of shutting down the VM's.
$results = $apicall.results.kind_reference_list.uuid

# Ensure previous Nutanix Sessions are disconnected
Disconnect-NTNXCluster *

Connect-NTNXCluster -Server "prism.redacted.com" -UserName $RESTAPIUser -Password $(ConvertTo-SecureString $RESTAPIPassword -AsPlainText -Force) -AcceptInvalidSSLCerts -ForcedConnection


foreach ($vmid in $results)
{
    $vmid = Get-NTNXVM -VmId $vmid
    if ($vmid.PowerState -eq "on") {
        Write-Host $vmid.uuid
        Set-NTNXVMPowerState -Vmid $vmid.uuid -Transition ACPI_SHUTDOWN -verbose
    }
}