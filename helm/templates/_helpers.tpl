{{/*
Expand the name of the chart.
*/}}
{{- define "isd-wiki.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "isd-wiki.fullname" -}}
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
{{- define "isd-wiki.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "isd-wiki.labels" -}}
helm.sh/chart: {{ include "isd-wiki.chart" . }}
{{ include "isd-wiki.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "isd-wiki.selectorLabels" -}}
app.kubernetes.io/name: {{ include "isd-wiki.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "isd-wiki.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "isd-wiki.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Environment shared by the mediawiki container and the init Job.

Both run the same image and the same docker-entrypoint.sh, so they need an
identical view of the database and site configuration. Defining it once keeps
the Job from silently drifting away from the Deployment - a Job pointed at the
wrong database would run update.php against it.
*/}}
{{- define "isd-wiki.mediawikiEnv" -}}
- name: MEDIAWIKI_DB_TYPE
  value: {{ .Values.mediawiki.database.type | quote }}
- name: MEDIAWIKI_DB_HOST
  value: {{ .Values.mediawiki.database.host | default (printf "%s-mysql" (include "isd-wiki.fullname" .)) | quote }}
- name: MEDIAWIKI_DB_PORT
  value: {{ .Values.mediawiki.database.port | default 5432 | quote }}
- name: MEDIAWIKI_DB_NAME
  valueFrom:
    secretKeyRef:
      name: {{ .Values.mediawiki.database.secretName | quote }}
      key: app-db-name
- name: MEDIAWIKI_DB_USER
  valueFrom:
    secretKeyRef:
      name: {{ .Values.mediawiki.database.secretName | quote }}
      key: app-db-username
- name: MEDIAWIKI_DB_PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ .Values.mediawiki.database.secretName | quote }}
      key: app-db-password
- name: MEDIAWIKI_SITE_NAME
  value: {{ .Values.mediawiki.siteName | quote }}
- name: MEDIAWIKI_SITE_SERVER
  value: {{ .Values.mediawiki.siteServer | quote }}
- name: MEDIAWIKI_ADMIN_USER
  valueFrom:
    secretKeyRef:
      name: {{ include "isd-wiki.fullname" . }}-credentials
      key: admin-user
- name: MEDIAWIKI_ADMIN_PASS
  valueFrom:
    secretKeyRef:
      name: {{ include "isd-wiki.fullname" . }}-credentials
      key: admin-password
- name: MEDIAWIKI_SMTP_HOST
  value: {{ .Values.mediawiki.smtp.host | quote }}
- name: MEDIAWIKI_SMTP_ID_HOST
  value: {{ .Values.mediawiki.smtp.idHost | quote }}
- name: MEDIAWIKI_SMTP_LOCALHOST
  value: {{ .Values.mediawiki.smtp.localhost | quote }}
- name: MEDIAWIKI_SMTP_PORT
  value: {{ .Values.mediawiki.smtp.port | quote }}
- name: MEDIAWIKI_SMTP_AUTH
  value: {{ .Values.mediawiki.smtp.auth | quote }}
{{- end }}
