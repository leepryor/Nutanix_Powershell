  <# 
  -------------------------------------------------------------------------------------
  |   Created by Lee Pryor                                                            |
  |   Objective: List VM's belonging to Prism category and issue a power down command.|
  |   Twitter: @devwrangler for any questions                                         |
  ------------------------------------------------------------------------------------- 
  #>

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

# Nutanix cluster and prism information
$prism = "prism.company.com"
$cluster = "cluster.company.com"

# Check to see if secure credential file exists. If not, prompts for credentials and creates file.
$CredPath = "C:\SecureString\SecureCredentials.xml"
$CredPathExists = [System.IO.File]::Exists($CredPath)

if ($CredPathExists -eq $false) {
  Get-Credential | EXPORT-CLIXML "$CredPath"
}

# Run at the start of each script to import the credentials
$Credentials = IMPORT-CLIXML "$CredPath"
$RESTAPIUser = $Credentials.UserName
$RESTAPIPassword = $Credentials.GetNetworkCredential().Password

# Nutanix Cluster and Prism REST API Connection information

$Uri = "https://$($prism):9440/api/nutanix/v3/category/query"
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

# Ensure previous Nutanix Sessions are disconnected and connect to cluster via Nutanix PoSH Cmdlets.
Disconnect-NTNXCluster *

Connect-NTNXCluster -Server $cluster -UserName $RESTAPIUser -Password $(ConvertTo-SecureString $RESTAPIPassword -AsPlainText -Force) -AcceptInvalidSSLCerts -ForcedConnection

# Iterate through hashtable to check to see if VM is powered on. If not, power down guest OS.
foreach ($vmid in $results)
{
    $vmid = Get-NTNXVM -VmId $vmid
    if ($vmid.PowerState -eq "on") {
        Write-Host $vmid.uuid
        Set-NTNXVMPowerState -Vmid $vmid.uuid -Transition ACPI_SHUTDOWN -verbose
    }
}