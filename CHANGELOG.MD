
# Change Log
All notable changes to this project will be documented in this file.

## [3.0.1] - 2021-05-21

### Fixed
- fixed userdata to reflect last changes to bbb-conf and find its URL and secrets 

### Changed
- image versions set to latest 1.1 image tags

## [3.0.0] - 2021-05-10

### Upgrade Notes: 
- the Big Blue Button version defaults now to 2.3.0. if you need to stay on 2.2.X please make sure to alter the BBB version parameter to xenial-22 and the Ubuntu version parameter to xenial-16.04. 
- the deployment now defaults to "Serverless" deployments for ECS and Aurora. this will optimize costs especially in small/test environments. switching from instanced to serverless will resetup the database means you will have to restore the DB from a backup afterwards or start fresh with testings. to prevent this, ensure you're not just using defaults for your environment.
- now you should have docker locally installed when planning a scalable deployment. this is due our approach to mirror the needed images to ensure availability when using scaling of the frontend and Scalelite LBs

### Fixed
- #75: Serverless Aurora did not deploy due a missing !IF condition for the parametergroup 
- #81: Single deployments failed due a missing condition

### Changed
- #84: Default Big Blue Button version defaults to 2.3.0 (stable since 7 Days)
- #77: SES automation is now optional and can be overwritten by using the parameter
- #77: an existing ACM Certificate ARN can be added to reuse an existing or imported SSL certificate
- #76: Cloudformation can now validate ACM certificates natively, so we do not need the custom resource anymore.
- #85: we're now utilizing IAM Roles when mounting the Shared Storage. Also the Storage now limits access to the APs utilizing these Roles. 
- #86: adding ECR as container registry to prevent failures due dockerhub limitations
- Versions of Greenlight and Scalelite are now current and reflect the new default Big Blue Button Version
- Fargate deployment version of Scalelite was broken, this is now fixed. 

## [2.3.0] - 2021-03-10

### Upgrade Notes: 
- Upgrading the Amazon Aurora Postgres Engine version via Amazon Cloudformation is not supported. Please refer to the official [upgrade documentation](https://docs.aws.amazon.com/AmazonRDS/latest/AuroraUserGuide/USER_UpgradeDBInstance.PostgreSQL.html) if you have a already running environment using an older engine version to proceed with the upgrade before reruning the Cloudformation deployment with default parameters. 
Alternatively you can set the parameter 'BBBDBEngineVersion' to the version you're currently using to prevent Amazon Cloudformation to try to upgrade. 

### Added
- #62: HTTP to HTTPS rewrites implemented
- #66: Added parameters to set the Big Blue Button application server root volume size

### Changed
- #63: default Amazon Aurora Postgres engine version updated to 12.4
- Updated Architectural Diagram for Serverless

## [2.2.0] - 2021-01-07

### Fixes
- #38: fixing deployment into Regions with < 3 AZs 

### Added
- #34: Optional deployment onto Aurora Serverless (Postgresql) for cost optimization especially with smaller deployments of a scalable solution
- #15: Optional deployment into a predefined/existing VPC containing at least Subnets in 2 AZs
- Parameter "BBBNumberOfAZs" to define how many AZs the deployment should utilize (=> also defines how many Subnets are used/created)

### Changed
- #44: Added section to prerequisites to ensure users are heads-up for common issues incl. missing service linked roles
- Big Blue Button Version String via parameter to make the version to be adjusted easily for upcoming Big Blue Button releases
- Application and Turn Server Ubuntu Versions are now parameterized. This ensures OS Versions can allign with the Big Blue Button Version used (e.g. for 2.3-dev deployments of BBB)
- Parameter BBBVPCcidr renamed into BBBVPCs
- BBBVPCs and BBB*Subnets parameters now take cidr blocks to create VPCs (and subnets) or IDs to reuse existing VPCs (and its subnets )
- Turn server Instance OS defaults to Ubuntu 20.04 LTS
- Removal of dedicated Contributing.md
- Restructure/Simplification of Conditions 
- Cleanup of unused conditions and parameters. 

## [2.1.0] - 2020-11-04

### Upgrade Notes: 
- Be sure to backup persistent storages if you use the single instance deplyoment mode before running the upgrade via setup.sh. The setup is backward compatible and will only adjust log group namings and streams. If you need or want to keep the already collected logs, export the data to S3 before running the upgrade process. 

### Changed
- #35: Log groups names are now more dynamic, allowing multble stacks in the same account as well as make it easier to locate related logs in Cloudwatch. Also the LogGroup strucure is simlified for better usability. 
- bump cfn-certificate-provider version to 0.2.5

### Fixes
- minor adjustments at the readme.md
- #42: Bump cfn-ses-provider version to 0.6.5

## [2.0.0] - 2020-11-03

### Upgrade Notes: 
- Be sure to backup especially your persistent storages like your recording storage before attempting the upgrade. the Changes in this Version will cause the EFS folder structure to be changed and simplyfied. 
If you decide to change the deployment type from EC2 based to AWS Fargate based architecure for Scalelite and Greenlight please make sure your ApplicationPrivateSubnet does have a reasonable size due each task will use it's very own IP address. 

To Upgrade, simply run the setup.sh with your parameters. Be sure to test and evaluate beforehand! 

### Added
- Optional AWS Fargate deployment instead of EC2 based deployment for Greenlight and scalelite #19
- containerized initialization for the EFS storage structure setup via Cloudformation, elimination of EC2 instance mount/mkdir hack #16
   
### Changed
- Default parameter settings for Desired ECS Instances have been lowered to 1. Max ECS Instance default settings have been lowered to 3. 
- Default Volume Size for Recordings EBS Storage have been lowered to 50G
- as the Instance Deployment for Turn and Application instances is pretty much settled, we shifted the cfn-signal command to the end of the bootstrap. this should ensure BBB is accessable pretty closely after the cloudformation deployment is done. 
- instance sizes for ECS Worker Instances and Application servers have been lowerd to the minimum needed to start a small test deployment to optize cost
- vCPU and memory limits of the ECS tasks have been simplified and are now set only on task level.

### Fixed
 
- Unreliable Turn and Application EC2 bootstraping due dkpg file locks
- Container Health Checks adjusted for more reliable service startups.
- #32
- #28

## [1.0.1] - 2020-11-04

### Changed
- bump cfn-certificate-provider version to 0.2.5

### Fixes
- #42: Bump cfn-ses-provider version to 0.6.5

## [1.0.0] - inital release

### inital version