
# Change Log
All notable changes to this project will be documented in this file.
 
## [0.0.1] - 2020-10-28

### Upgrade Notes: 
- Be sure to backup especially your persistent storages like your recording storage before attemting the upgrade. the Changes in this Version will cause the EFS folder structure to be changed and simplyfied. 
If you decide to change the deployment type from EC2 based to AWS Fargate based architecure for Scalelite and Greenlight please make sure your ApplicationPrivateSubnet does have a reasonable size due each task will use it's very own IP address. 

To Upgrade, simply run the setup.sh with your parameters. Be sure to test and evaluate beforehand! 

### Added
- Optional AWS Fargate deployment instead of EC2 based deployment for Greenlight and scalelite #19
- containerized initialization for the EFS storage structure and initial admin account creation via tasks #16
   
### Changed
- Default parameter settings for Desired ECS Instances have been lowered to 1. Max ECS Instance default settings have been lowered to 3. 
- Default Volume Size for Recordings EBS Storage have been lowered to 50G
- as the Instance Deployment for Turn and Application instances is pretty much settled, we shifted the cfn-signal command to the end of the bootstrap. this should ensure BBB is accessable pretty closely after the cloudformation deployment is done. 

### Fixed
 
- Unreliable Turn and Application EC2 bootstraping due dkpg file locks
- Container Health Checks adjusted for more reliable service startups.
- #32
- #28