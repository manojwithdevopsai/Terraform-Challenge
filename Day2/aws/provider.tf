terraform {
  required_providers {
    aws = {
      source = "hashicorp/aws"
      version = "6.11.0"
    }
  }
}

provider "aws" {
region = "us-east-1"
alias = "project1"

}

provider "aws" {
region = "us-west-1"
alias = "project2"

}
