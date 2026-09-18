# Infrastructure state only. The platform root uses a separate key.
terraform {
  backend "s3" {}
}
