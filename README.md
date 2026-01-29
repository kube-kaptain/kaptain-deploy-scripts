# Kaptain Deploy Scripts

This project contains Kaptain's portable Kubernetes deployment system scripts.
When combined with a compatible base image these should work fine on any Kube
and on any cloud, EKS, GKE, AKS, and others.


# Testing Matrix

These scripts have a suite of bats unit tests that are run against a full
matrix of in-house environment base images that they'll later be combined
with. This provides confidence in both the scripts and the images.


# Packaging

These scripts are deployed in a bare from-scratch docker image that can then
be used by any down stream deployment image build to provide a consistent
experience regardless of which flavour of Linux you choose. The included
`validate-tooling` script allows those images to be validated against the
requirements of the scripts to ensure they have a good chance of working IRL.


# Validate Scripts

Three validation scripts are included in this package:

1. `validate-tooling` - runs here during testing and in deploy image builds
2. `validate-environment` - runs after an environment build before publishing
3. `validate-container` - runs only during execution of the end user image

The deploy script runs all three in sequence so you've got maximum coverage as
late in the piece as possible. The `validate-environment` script cannot be run
until the final environment image is built so it's only valid then and at
runtime. The `validate-container` script is only valid at runtime since it just
checks things that the others can't that are only present at runtime. The
`validate-tooling` script is useful in this project to validate the base image
we're about to test against is suitable as well as during the deployment image
builds using these scripts and those base images or potentially other custom
base images - Arch or Gentoo based env image, anyone? :-)
