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
