
# Change Log
All notable changes to this project will be documented in this file.
 
## [0.0.1] - 2020-10-28
 
### Added
- Optional AWS Fargate deployment instead of EC2 based deployment for Greenlight and scalelite #19
- containerized initialization for the EFS storage structure and initial admin account creation via ECS one-shot tasks #16
   
### Changed
- Default parameter settings for Desired ECS Instances have been lowered to 1. Max ECS Instance default settings have been lowered to 3. 
- Default Volume Size for Recordings EBS Storage have been lowered to 50G

### Fixed
 
- Unreliable Turn and Application EC2 bootstraping due dkpg file locks
- Container Health Checks adjusted for more reliable service startups.
- #32
- #28