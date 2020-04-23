<#

.SYNOPSIS
This script is used to mass delete snapshots that belong to unmanaged/relic objects. The initial run will generate a CSV for review. Remove any Objects that you do not wish to have deleted. Once the modifications are made re-run this script using the -DeleteObjects flag to initiate the removal. 

NOTE: When reviewing the CSV file please remove all lines that reference an object you wish to keep. This script does not have a per snapshot deletion granularity. If the object ID is present within the CSV file all snapshots related to that object ID will be removed.


.EXAMPLE

.\ManageUnmanagedObjects.ps1 -rubrikAddress 10.35.18.192 -LocationDetails

Generates a list of unmanaged objects and their snapshots while also providing location information for the relevant object types. For example a VMware VM would report which ESX host it lived on, while a MSSQL DB would report the windows server.


.EXAMPLE
.\ManageUnmanagedObjects.ps1 -rubrikAddress 10.35.18.192 -DeleteObjects -CSVFile TestCluster_Unmanaged_snapshot_report_202003201012.csv

After reviewing the CSV and removing any objects you desire to keep this command will delete the objects that remain within the CSV.

.EXAMPLE
.\ManageUnmanagedObjects.ps1 -rubrikAddress 10.35.18.192 -DeleteSnaps -CSVFile TestCluster_Unmanaged_snapshot_report_202003201012.csv

After reviewing the CSV and removing any snapshots you desire to keep this command will delete the snapshots that remain within the CSV. This differs from -DeleteObjects as it provides a per snapshot deletion rather than removing all snaps associated with a specific object.

#>





param ([cmdletbinding()]
    [parameter(Mandatory=$false)]
    [switch]$DeleteObjects,
    [parameter(Mandatory=$false)]
    [string]$rubrikAddress,
    [parameter(Mandatory=$false)]
    [switch]$LocationDetails,
    [parameter(Mandatory=$false)]
    [string]$CSVFile,
    [parameter(Mandatory=$false)]
    [switch]$DeleteSnaps
    )

Import-Module Rubrik
#$RubrikCredential = Get-Credential -Message "Enter Rubrik credential"
#Connect-Rubrik $rubrikAddress -Credential $RubrikCredential
$RubrikName = (Get-RubrikVersion).name
$mdate = (Get-Date).tostring("yyyyMMddHHmm")

if($DeleteSnaps){
    #WARNING
    #This will delete all snapshots in the CSV file provided.
    $unmanaged_snap_report = Import-Csv $CSVFile
    if([string]::IsNullOrEmpty($unmanaged_snap_report)){
        #End Script Here
        Write-Host "CSV File Not Found. Please use the -CSVFile flag specify a valid CSV file."
        exit
    }
    Write-host "Would you like to delete all of the snapshots for the objects referenced above? (Default is No)" -ForegroundColor Yellow 
    $Readhost = Read-Host " ( y / n ) " 
    Switch ($ReadHost) 
     { 
       Y {Write-host "Yes, starting the deletion process."; $deletionapproval=$true} 
       N {Write-Host "No, exiting out of the script."; $deletionapproval=$false} 
       Default {Write-Host "Default, exiting out of the script."; $deletionapproval=$false} 
     } 




        if($deletionapproval){
            $RelicObjects = $unmanaged_snap_report | Where-Object {$_.unmanagedSnapshotType -ne "OnDemand"}
            $RelicObjectsCount = ($RelicObjects | Measure-Object).Count
            if($RelicObjectsCount -gt 0){
                $RelicObjectIDs = $RelicObjects.Object_ID | Get-Unique
                $RelicObjectIDs = $RelicObjectIDs -join '","'

                #Assign UNPROTECTED retention SLA so the snaps are eligible for deleteion
                #Note the way the managedIds work is you need to have the full ID (example: Fileset:::6170833a-d17a-4184-bc77-0b626423a167), and you can send multiple into the same call using "" and separating via a , 
                $RelicJsonBody = @"
                {
                    "slaDomainId": "UNPROTECTED",
                    "managedIds": [
                        "$RelicObjectIDs"
                    ]
                }
"@
#Wait-Debugger
                #Update SLA of reliced objects to UNPROTECTED
                Invoke-RubrikRESTCall -Endpoint "unmanaged_object/assign_retention_sla" -Method POST -Body ($RelicJsonBody | ConvertFrom-Json) -api internal 

            }
            

                #Assign UNPROTECTED SLA to OnDemand Snapshots
                $OnDemandSnaps = $unmanaged_snap_report | Where-Object {$_.unmanagedSnapshotType -eq "OnDemand"}
                $OnDemandCount = ($OnDemandSnaps | Measure-Object).Count
                if($OnDemandCount -gt 0){
                    $OnDemandSnapshotIds = $OnDemandSnaps.Snapshot_ID
                    $OnDemandSnapshotIds = $OnDemandSnapshotIds -join '","'
                    $OnDemandJsonBody = @"
                    {
                        "slaDomainId": "UNPROTECTED",
                        "snapshotIds": [
                            "$OnDemandSnapshotIds"
                        ]
                    }
"@
                    Invoke-RubrikRESTCall "unmanaged_object/snapshot/assign_sla" -Method POST -Body ($OnDemandJsonBody | ConvertFrom-Json) -api internal 

                }
               
                
                #Setup individual Snapshot Handling for each Object.
                $UniqueObjectIds = $unmanaged_snap_report.Object_ID | Get-Unique
                foreach($object in $UniqueObjectIds){
                    #Generate a list of snapshots for each unique Object
                    $snapslist = $unmanaged_snap_report | Where-Object {$_.Object_ID -eq $object}
                        $listofsnapstodelete = $snapslist.Snapshot_ID
                        $listofsnapstodelete = $listofsnapstodelete -join '","'
                        $DeleteSnapBody = @"
                        {
                            "snapshotIds": [
                                "$listofsnapstodelete"
                            ]
                        }
"@
#Wait-Debugger
                        #Run the deletion of all snaps contained within the CSV file. 
                        Invoke-RubrikRESTCall -Endpoint ("unmanaged_object/" + $object + "/snapshot/bulk_delete") -Method POST -Body ($DeleteSnapBody| ConvertFrom-Json) -api internal 
                        Write-Host ("Deleted the snapshots for " + $object)
                    
                } 
        }


     exit


#############################################################################################################################################################
}

if($DeleteObjects){
#WARNING
#If invoked this flag will delete every snapshot for the objects named in the Unmanaged_snapshot_report.csv

    $unmanaged_snap_report = Import-Csv $CSVFile
    if([string]::IsNullOrEmpty($unmanaged_snap_report)){
        #End Script Here
        Write-Host "CSV File Not Found. Please use the -CSVFile flag specify a valid CSV file."
        exit
    }
    $unmanaged_snap_report = $unmanaged_snap_report | Select-Object Object_Name,Object_ID,Object_Type
    $unmanaged_snap_report = $unmanaged_snap_report |Get-Unique -AsString 
    $unmanaged_snap_report

    Write-host "Would you like to delete all of the snapshots for the objects referenced above? (Default is No)" -ForegroundColor Yellow 
    $Readhost = Read-Host " ( y / n ) " 
    Switch ($ReadHost) 
     { 
       Y {Write-host "Yes, starting the deletion process."; $deletionapproval=$true} 
       N {Write-Host "No, exiting out of the script."; $deletionapproval=$false} 
       Default {Write-Host "Default, exiting out of the script."; $deletionapproval=$false} 
     } 
   if($deletionapproval){
    foreach($object in $unmanaged_snap_report){
        if($object.Object_Type -eq "MssqlDatabase"){
            Write-Host ("Deleting the snapshots for " + $object.Object_Name)
            Invoke-RubrikRESTCall -Endpoint ("mssql/db/" + $object.Object_ID + "/snapshot") -Method DELETE -api 1 -Verbose
        }
        if($object.Object_Type -eq "VirtualMachine"){
            Write-Host ("Deleting the snapshots for " + $object.Object_Name)
            Invoke-RubrikRESTCall -Endpoint ("vmware/vm/" + $object.Object_ID +"/snapshot") -Method DELETE -api 1 -Verbose
        }
        if($object.Object_Type -eq "ShareFileset"){
            Write-Host ("Deleting the snapshots for " + $object.Object_Name)
            Invoke-RubrikRESTCall -Endpoint ("fileset/" + $object.Object_ID +"/snapshot") -Method DELETE -api 1 -Verbose
        }
        if($object.Object_Type -eq "HypervVirtualMachine"){
            Write-Host ("Deleting the snapshots for " + $object.Object_Name)
            Invoke-RubrikRESTCall -Endpoint ("hyperv/vm" + $object.Object_ID +"/snapshot") -Method DELETE -api internal -Verbose
        }
        if($object.Object_Type -eq "LinuxFileset"){
            Write-Host ("Deleting the snapshots for " + $object.Object_Name)
            Invoke-RubrikRESTCall -Endpoint ("fileset/" + $object.Object_ID +"/snapshot") -Method DELETE -api 1 -Verbose
        }
        if($object.Object_Type -eq "WindowsFileset"){
            Write-Host ("Deleting the snapshots for " + $object.Object_Name)
            Invoke-RubrikRESTCall -Endpoint ("fileset/" + $object.Object_ID +"/snapshot") -Method DELETE -api 1 -Verbose
        }
        if($object.Object_Type -eq "VolumeGroup"){
            Write-Host ("Deleting the snapshots for " + $object.Object_Name)
            Invoke-RubrikRESTCall -Endpoint ("volume_group/" + $object.Object_ID +"/snapshot") -Method DELETE -api internal -Verbose
        }

   }
   }
}


if(!($DeleteObjects)){

    Write-Host "Generating a list of Unmanaged Objects
    
    "
    $ClusterInfo = Get-RubrikClusterInfo
    #$unmanaged_objects = Get-RubrikUnmanagedObject
    $unmanaged_objects = @()
    #Need to work on using the limit functionality of this endpoint in order to work with larger clusters. Can be something like:
    # while hasMore = $true {(Invoke-RubrikRESTCall -Endpoint "unmanaged_object?limit=10&after_id=MssqlDatabase%3A%3A%3A5b0d0173-07a9-4ba8-ab09-cf9315be8d32" -Method GET -api internal)}
    $unmanagedObjectList = Invoke-RubrikRESTCall -Endpoint "unmanaged_object?limit=50" -Method GET -api internal
    $unmanaged_objects += $unmanagedObjectList.data
    $lastunmanagedObject = ($unmanagedObjectList.data | Select-Object -last 1).id 
    while ($unmanagedObjectList.hasMore -eq $True){
        $unmanagedObjectList = Invoke-RubrikRESTCall -Endpoint ("unmanaged_object?limit=50&after_id=" + $lastunmanagedObject) -Method GET -api internal
        $unmanaged_objects += $unmanagedObjectList.data
        $lastunmanagedObject = ($unmanaged_objects | Select-Object -Last 1).id
    }

    Write-Host ("Found " + ($unmanaged_objects | measure-Object).count + " Unmanaged Objects
    
    ")
    Write-Host "Will Begin gathering snapshot information for each of the unmanaged objects."
    if($LocationDetails){
        Write-Host "Will also obtain location details for each of the objects. "
    }
    $objectindex = 1 
    foreach($object in $unmanaged_objects){
        Write-Host ("
Getting snaps for " + $object.name)
        Write-Host ("Object " + $objectindex + " of " + ($unmanaged_objects | measure-Object).count)
        $snapshots = (Invoke-RubrikRESTCall -Endpoint ("unmanaged_object/"+ $object.id + "/snapshot") -Method GET -api internal).data
        $snaplist = @()
        #Generate Location Information at the Object Level

        if($LocationDetails){
            if($object.objectType -eq "VirtualMachine"){
                $VMinfo = Get-RubrikVM -id $object.id
                $location = ($VMinfo.currentHost).name
                $clusterUUID = $VMinfo.primaryClusterId
                $ReplRelic = $ClusterInfo.id -ne $clusterUUID

            }
            if($object.objectType -eq "MssqlDatabase"){
                $DBInfo = Get-RubrikDatabase -id $object.id
                $location = ($DBInfo.rootProperties).rootName
                $clusterUUID = $DBInfo.primaryClusterId
                $ReplRelic = $ClusterInfo.id -ne $clusterUUID
            }
            if($object.objectType -match "Fileset"){
                $filesetInfo = Get-RubrikFileset -id $object.id
                $location = $filesetInfo.hostName
                $clusterUUID = $filesetInfo.primaryClusterId
                $ReplRelic = $ClusterInfo.id -ne $clusterUUID
            }
            if($object.objectType -match "HypervVirtualMachine"){
                $HyperVInfo = Get-RubrikHyperVVM -id $object.id
                $location = (($HyperVInfo.infraPath) | where-object {$_.id -match "HypervServer"}).name
                $HyperVClusterName = (($HyperVInfo.infraPath) | where-object {$_.id -match "HypervCluster"}).name
                $clusterUUID = $HyperVInfo.primaryClusterId
                $ReplRelic = $ClusterInfo.id -ne $clusterUUID
            }
            if($object.objectType -match "VolumeGroup"){
                $VolumeGroupInfo = Get-RubrikVolumeGroup -id $object.id
                $location = $VolumeGroupInfo.hostName
                $VolumeGroupDrives = $VolumeGroupInfo.Includes
                $clusterUUID = $VolumeGroupInfo.primaryClusterId
                $ReplRelic = $ClusterInfo.id -ne $clusterUUID
            }
        }

        foreach($snap in $snapshots){
            $snapshot_stats = New-Object psobject
            $snapshot_stats | Add-Member -NotePropertyName "Object_Name" -NotePropertyValue $object.name
            $snapshot_stats | Add-Member -NotePropertyName "Object_ID" -NotePropertyValue $object.id
            $snapshot_stats | Add-Member -NotePropertyName "Object_Type" -NotePropertyValue $object.objectType
            $snapshot_stats | Add-Member -NotePropertyName "Snapshot_ID" -NotePropertyValue $snap.id
            $snapshot_stats | Add-Member -NotePropertyName "unmanagedSnapshotType" -NotePropertyValue $snap.unmanagedSnapshotType

            # Use the previously generated location information and apply it at the snapshot level. 
            if($LocationDetails){
                $snapshot_stats | Add-Member -NotePropertyName "Location" -NotePropertyValue ""
                $snapshot_stats | Add-Member -NotePropertyName "PrimaryClusterUUID" -NotePropertyValue ""
                $snapshot_stats | Add-Member -NotePropertyName "ReplicaRelic" -NotePropertyValue $ReplRelic
                if($snapshot_stats.Object_Type -eq "VirtualMachine"){
                    $snapshot_stats.Location = $location
                    $snapshot_stats.PrimaryClusterUUID = $clusterUUID
                }
                if($snapshot_stats.Object_Type -eq "MssqlDatabase"){
                    $snapshot_stats.Location = $location
                    $snapshot_stats.PrimaryClusterUUID = $clusterUUID
                }
                if($snapshot_stats.Object_Type -match "Fileset"){
                    $snapshot_stats.Location = $location
                    $snapshot_stats.PrimaryClusterUUID = $clusterUUID
                }
                if($snapshot_stats.Object_Type -match "HypervVirtualMachine"){
                    $snapshot_stats.Location = $location
                    $snapshot_stats | Add-Member -NotePropertyName "HyperVClusterName" -NotePropertyValue "$HyperVClusterName"
                    $snapshot_stats.PrimaryClusterUUID = $clusterUUID
                }
                if($snapshot_stats.Object_Type -match "VolumeGroup"){
                    $snapshot_stats.Location = $location
                    $snapshot_stats | Add-Member -NotePropertyName "VolumeGroupDrives" -NotePropertyValue "$VolumeGroupDrives"
                    $snapshot_stats.PrimaryClusterUUID = $clusterUUID
                }
            }
            $snapshot_stats | Add-Member -NotePropertyName "Date" -NotePropertyValue $snap.date
            $snapshot_stats | Add-Member -NotePropertyName "RetentionSLADomainID" -NotePropertyValue $snap.retentionSlaDomainId
            $snapshot_stats | Add-Member -NotePropertyName "RetentionSLADomainName" -NotePropertyValue $snap.retentionSlaDomainName
            $snaplist += $snapshot_stats

        }
    $objectindex++ 
    $unmanaged_snap_report += $snaplist

}
Write-Host ("Saving Unmanaged Snapshot information to " + $RubrikName + "_Unmanaged_snapshot_report_" + $mdate + ".csv")

    $unmanaged_snap_report | Export-Csv -NoTypeInformation ($RubrikName + "_Unmanaged_snapshot_report_" + $mdate + ".csv")

    Write-Host "Please review the Unmanaged snapshot CSV before re-running this script with the -DeleteObjects flag to remove the snapshots for those objects
    
     WARNING: ANY OBJECT IDS LEFT IN THE CSV FILE WILL HAVE ALL OF THEIR SNAPSHOTS DELETED, AND THERE IS NO WAY TO REVERT THIS TASK AFTERWARD.
     PLEASE BE VERY SURE BEFORE RE-RUNNING THE SCRIPT WITH THE -DeleteObjects FLAG
     
     USE THE -CSVFile FLAG TO PROVIDE THE CSV FILE YOU WOULD LIKE TO USE DURING THE DELETION PROCESS"
}
