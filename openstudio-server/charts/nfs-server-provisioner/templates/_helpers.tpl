{{/* vim: set filetype=mustache: */}}
{{/*
Expand the name of the chart.
*/}}
{{- define "nfs-provisioner.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "nfs-provisioner.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default .Chart.Name .Values.nameOverride -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "nfs-provisioner.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "nfs-provisioner.provisionerName" -}}
{{- if .Values.storageClass.provisionerName -}}
{{- printf .Values.storageClass.provisionerName -}}
{{- else -}}
cluster.local/{{ template "nfs-provisioner.fullname" . -}}
{{- end -}}
{{- end -}}

{{- define "nfs-provisioner.registryHost" -}}
{{- $global := default (dict) .Values.global -}}
{{- $images := default (dict) (get $global "images") -}}
{{- $registry := trimSuffix "/" (default "" (get $images "registry")) -}}
{{- if and (ne $registry "") (not (regexMatch ".*[.:].*" $registry)) -}}
{{- fail (printf "global.images.registry=%q is invalid. Use a registry host[:port], not a bare namespace." $registry) -}}
{{- end -}}
{{- $registry -}}
{{- end -}}

{{- define "nfs-provisioner.imageWithRegistry" -}}
{{- $image := default "" .image -}}
{{- $global := default (dict) .root.Values.global -}}
{{- $images := default (dict) (get $global "images") -}}
{{- $registry := include "nfs-provisioner.registryHost" .root -}}
{{- $repositoryPrefix := trimAll "/" (default "" (get $images "repositoryPrefix")) -}}
{{- if or (regexMatch "^(localhost|[^/]+[.:][^/]+)/.+" $image) (eq $registry "") -}}
{{- $image -}}
{{- else -}}
{{- $pathParts := list -}}
{{- if ne $repositoryPrefix "" -}}
{{- $pathParts = append $pathParts $repositoryPrefix -}}
{{- end -}}
{{- $pathParts = append $pathParts $image -}}
{{- printf "%s/%s" $registry (join "/" $pathParts) -}}
{{- end -}}
{{- end -}}
