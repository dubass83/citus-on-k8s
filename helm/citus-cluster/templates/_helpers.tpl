{{/*
Expand the name of the chart.
*/}}
{{- define "citus-cluster.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "citus-cluster.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "citus-cluster.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "citus-cluster.labels" -}}
helm.sh/chart: {{ include "citus-cluster.chart" . }}
{{ include "citus-cluster.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "citus-cluster.selectorLabels" -}}
app.kubernetes.io/name: {{ include "citus-cluster.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "citus-cluster.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default .Values.clusterName .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Common Patroni labels for coordinator
*/}}
{{- define "citus-cluster.coordinatorLabels" -}}
application: {{ .Values.application }}
cluster-name: {{ .Values.clusterName }}
citus-group: {{ .Values.coordinator.citusGroup | quote }}
citus-type: {{ .Values.coordinator.citusType }}
{{- end }}

{{/*
Common Patroni labels for worker group
*/}}
{{- define "citus-cluster.workerLabels" -}}
application: {{ .Values.application }}
cluster-name: {{ .Values.clusterName }}
citus-group: {{ .citusGroup | quote }}
citus-type: {{ .citusType }}
{{- end }}

{{/*
Kubernetes labels for Patroni
*/}}
{{- define "citus-cluster.patroniKubernetesLabels" -}}
{application: {{ .Values.application }}, cluster-name: {{ .Values.clusterName }}}
{{- end }}
