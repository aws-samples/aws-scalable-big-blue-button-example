
# Change Log

All notable changes to this project will be documented in this file.

## [5.0.0] - 2023-06-15
### Upgrade Notes: 
- Upgrading the Amazon Aurora Postgres Engine version and/or the switch to Aurora Serverless v2 via Amazon Cloudformation is not supported. Please refer to the official [upgrade documentation](https://docs.aws.amazon.com/AmazonRDS/latest/AuroraUserGuide/USER_UpgradeDBInstance.PostgreSQL.html) and [migrate to Aurora Serverless v2](https://docs.aws.amazon.com/AmazonRDS/latest/AuroraUserGuide/aurora-serverless-v2.upgrade.html) if you have a already running environment using an older engine version and/or Aurora Serverless v1 to proceed with the upgrade before using the Cloudformation deployment. 
- Greenlight Updated to version 3 which will come with some major changes to the startup scripts. 5.0.0 of the deployment will not be compatible to Greenligth version 2 based deployments anymore. If you need to stay with Greenlight version 2 please use version 4.5.0 of the deployment codebase. 
- Due the change in how we utilize the most recent AMI for Ubuntu, double check your parameter file (bbb-on-aws-param.json) if you customized it to reflect the switch to the new parameters BBBApplicationInstanceAMIParameter and containing the path to the fitting AMI SSM Parameter Store object. 
- seperate turn servers has been removed from the deployment. this also means big blue button versions prior 2.6 cannot be used with these templates anymore as the prior versions do not support the included turn server install.

### Changed
- Aurora Engine Version now on 14.3
- ExecutionCommand Enabled for the ECS cluster, tasks are extended to be able to use aws ecs cli commands to log into the tasks for debug purposes
- Update Big Blue Button version to 2.6 
- Update Greenlight to version 3
- Update Scalelite to version 1.5
- Bootstrap Scripts moved to seperate bash script files for easier access for customization and lean cfn template. 
- Removed the Instance Class/Familie restrictions from the templates. Still you need to use valid instances though depending on which are available for Amazon EC2, Amazon Elasticache and Amazon RDS. 
- Removed the Custom AMI finder and relate to AWS Parameter Store default offering via resolve Function
- Switched from the docker pull, push to ECR local workflow to ECR pull through cache. 
- Added scanonPush to the ECR registry for security scaning before delivery to the app servers
- Removed the need for server-handler task to add and remove BBB Application server instances. commands are executed now directly at the scalelite-api task via the application server instance. This will speed up adding/removing of meeting servers. 
- Removal of the seperate turn server. the turn server is now integrated into each BBB Application Server Instance seperately
- updated cli53 version to 0.8.22
- updated aws-cli v1 to v2


## [4.5.0] - 2022-10-06
### Upgrade Notes: 
- Upgrading the Amazon Aurora Postgres Engine version and/or the switch to Aurora Serverless v2 via Amazon Cloudformation is not supported. Please refer to the official [upgrade documentation](https://docs.aws.amazon.com/AmazonRDS/latest/AuroraUserGuide/USER_UpgradeDBInstance.PostgreSQL.html) and [migrate to Aurora Serverless v2](https://docs.aws.amazon.com/AmazonRDS/latest/AuroraUserGuide/aurora-serverless-v2.upgrade.html) if you have a already running environment using an older engine version and/or Aurora Serverless v1 to proceed with the upgrade before using the Cloudformation deployment. 

### Fixed
- lambda python runtimes updated to supported version
- Ensure database names begin with letter
- Application version parameter is now passed through needed nested stacks

### Changed
- Aurora Serverless switched to Aurora Serverless v2 
- Aurora Engine Version now on 13.7
- Update Big Blue Button version to 2.5 
- Application Server OS now on Ubuntu 20.04 
- upgraded cfn-ses-provider to v0.8.3 

### Added
- Parameter to enable/disable the deployment of Greenlight for the scalable setup. This enables you to have a deployment prepared to be used with an external LMS or Frontend in general. this change disables the Greenlight Tasks, Services, ALB deployments, DNS entries, setup of SES and SMTP User and referred Roles. Parameter: "BBBFrontendType" valid values: Greenlight, External

## [4.0.0] - 2022-05-28

### Fixed
- #112: switch parameters and variables to dynamic variables which should enable multi deployments at the same AWS Account. 

### Changed
- Removed unused Parameters 
- Randomized Database Naming 
- upgraded cfn-ses-provider to v0.8.2
- remove of any CW alarms as this should be customized per environment 

## [3.0.7] - 2022-05-28

### Fixed
- #113: Admin Password adds punktuation so greenlight bootstrapping does work again
- BBB Version pushed to 2.4 (2.3 seems broken atm)

## [3.0.4] - 2021-11-11

### Fixed
- #104: setup.sh is now checking for a running docker daemon and exists if not found
- #101: adding _netdev to fstab to prevent loss of storage mount on reboots
- #103: fixing the SNS topic encryption to allow SES notification sendout
- #99: improved the command within the greenlight task. basically extended the default /bin/start instead of the old quick and dirty hack. 

### Changed
- renamed the root stack yaml file
- scalelite version push to 1.3
- Aurora Default Engine version pushed to 10.14
## [3.0.3] - 2021-05-27

### Fixed
- #98: destroy.sh does now also purge all versions of source s3 and deletes the bucket 
## [3.0.2] - 2021-05-27

### Fixed
- #89: destroy.sh does now also purge and delete the ECR repos

### Changed
- #90: Source S3 Bucket now does have encryption and versioning enabled
- #91: SNS Topic is now encrypted by default
- #92: cfn-ses-provider and cli53 have been updated to the current version
- SES Identity Notifications have been (temp) disabled due incompatibility with encrypted SES topics

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