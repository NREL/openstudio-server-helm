# OpenStudio Server - Version Compatibility Matrix

This document provides version compatibility information for OpenStudio Server Helm chart deployments.

## Current Deployment (as of June 2026)

| Component | Version | Notes |
|-----------|---------|-------|
| **Helm Chart** | 0.5.2 | Located in `openstudio-server/` directory |
| **OpenStudio Server** | 3.10.0 | Image: `openstudio-server:3.10.0` (from ECR) |
| **OpenStudio Rserve** | 3.10.0 | Image: `openstudio-rserve:3.10.0` (from ECR) |
| **Kubernetes** | 1.27+ | Minimum required version |
| **Helm CLI** | 3.12.0+ | Minimum required version |
| **kubectl** | 1.27.0+ | Minimum required version |

## Known Compatibility Issues

### Issue #47: OpenStudio/PAT Compatibility
**Problem:** OpenStudio models created in OS App 1.5.0 and PAT 3.5.0/3.5.1 fail to progress past "creating analysis" on server

**Current Status:** Investigating. This may be related to:
- Helm chart version mismatch with application version
- Measure compatibility (measures from BCL may require specific versions)
- OpenStudio SDK version mismatches between local tools and server deployment

**Recommendation:** Users should verify that their local OpenStudio App and PAT versions match the server deployment version (3.10.0).

### Note: AppVersion Mismatch
The `Chart.yaml` specifies `appVersion: 3.7.0`, but actual deployed images are `3.10.0`. This should be updated for clarity.

## Recommended Version Combinations

For best compatibility, use the following versions together:

| Use Case | OS App | PAT | Helm Chart | OpenStudio Server | Notes |
|----------|--------|-----|------------|-------------------|-------|
| Current Production | 1.5.0+ | 3.5.0+ | 0.5.2 | 3.10.0 | Latest stable configuration |
| Legacy | 1.4.0 | 3.4.0 | 3.4.0 | 3.4.0 | Older, tested combination |

## Migration Path

When upgrading versions:

1. **Update Local Tools First**: Upgrade OpenStudio App and PAT on your local machine
2. **Export Models**: Export your OSM models from the newer app version
3. **Update Helm Chart**: Update the Helm chart version in this repository
4. **Update Image Tags**: Modify `values.yaml` to use newer image versions
5. **Deploy & Test**: Deploy to a staging cluster and run test simulations
6. **Verify Measure Compatibility**: Ensure your measures work with the new OpenStudio SDK version

## Measure Compatibility

**Important:** Measures from the OpenStudio Measure Building Component Library (BCL) are versioned independently of OpenStudio releases. When using newer server versions:

- Measures compiled against older SDK versions may not be compatible
- Check BCL documentation for measure requirements
- Consider maintaining a local measure library with known-good versions
- Test measures in staging before deploying to production

## Cloud Provider Requirements

### AWS EKS
- EBS CSI Driver: Required for Kubernetes 1.23+
- Kubernetes Version: 1.27+ (as per Chart requirements)

### Google GKE
- Persistent Disk provisioner: Built-in
- Kubernetes Version: 1.27+

### Azure AKS
- Managed Disk provisioner: Built-in
- Kubernetes Version: 1.27+

### OpenStack
- Cinder storage driver: Required
- Kubernetes Version: 1.27+

## Troubleshooting Version Issues

### Symptom: Pods stuck in "Pending" state
- **Cause:** Often related to storage class configuration
- **Solution:** Ensure `volumeBindingMode: WaitForFirstConsumer` is set in storage classes (See PVC Binding Mode fix in this repository)

### Symptom: Image pull failures
- **Cause:** Image tags may not exist in your container registry
- **Solution:** Verify that container images are pushed to your ECR/registry before deployment

### Symptom: Simulations fail with SDK errors
- **Cause:** Measure/version incompatibility
- **Solution:** Verify that measures are compatible with the deployed OpenStudio SDK version

## Support & Reporting

For version-related issues:
1. Check GitHub issues: https://github.com/NatLabRockies/openstudio-server-helm/issues
2. Report new issues with the exact versions you're using
3. Include relevant Kubernetes event logs and pod descriptions
4. Attach a sample model that reproduces the issue (if possible)

---

**Last Updated:** June 27, 2026
**Chart Version:** 0.5.2
**Current Server Version:** 3.10.0
