{{/*
Expand the name of the chart.
*/}}
{{- define "mediawiki.name" -}}
{{- default .Chart.Name .Values.mediawiki.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}


{{- define "mediawiki.fullname" -}}
{{- if and .Values.mediawiki (hasKey .Values.mediawiki "fullnameOverride") }}
{{- .Values.mediawiki.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name (and .Values.mediawiki (get .Values.mediawiki "nameOverride")) }}
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
{{- define "mediawiki.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "mediawiki.labels" -}}
helm.sh/chart: {{ include "mediawiki.chart" . }}
{{ include "mediawiki.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "mediawiki.selectorLabels" -}}
app.kubernetes.io/name: {{ include "mediawiki.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "mediawiki.serviceAccountName" -}}
{{- if .Values.mediawiki.serviceAccount.create }}
{{- default (include "mediawiki.fullname" .) .Values.mediawiki.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.mediawiki.serviceAccount.name }}
{{- end }}
{{- end }}
