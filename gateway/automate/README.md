# API Gateway Automation

This project automates the deployment of API Gateway configurations for BC Government services using [API Program Services (APS)](https://developer.gov.bc.ca/docs/default/component/aps-infra-platform-docs/). The system uses a Python script to inject secrets from HashiCorp Vault into a Kong Gateway configuration yaml file.

## Overview

The automation process consists of three main components:

1. **Environment Configuration (`.env`)** - Defines vault paths and system configuration
2. **Template Configuration (`gw-ssl-vault.yaml`)** - Kong Gateway configuration template with vault references
3. **Injection Script (`script.py`)** - Python script that resolves vault secrets and environment variables


NOTE: This script is tuned to a specific gateway with intentional env vars; however, it can be expanded to fit other use cases following the env var substitution patterned outlined below.
## Prerequisites

1. **[GWA CLI](https://developer.gov.bc.ca/docs/default/component/aps-infra-platform-docs/how-to/gwa-install/)** - For deploying gateway configurations
2. **[Vault CLI](https://developer.hashicorp.com/vault/install)** - Must be installed and added to system PATH
3. **Vault Authentication** - You must be authenticated to vault before running the script
4. **[Common Single Sign-on](https://sso-requests.apps.gold.devops.gov.bc.ca/)** - SSO client must be configured
5. **Python Dependencies**:
   ```bash
   pip install pyyaml python-dotenv
   ```
6. **Vault Secrets** - All referenced secrets must exist at the specified vault paths (in .env)

## ABOUT

### 1. Environment Configuration (`.env`)

The `.env` file contains three types of configuration:

- **Vault Secret Paths**: References to secrets stored in HashiCorp Vault
- **Machine Configuration**: Local system settings (vault executable path)
- **Gateway Configuration**: Service-specific settings and runtime parameters

Key environment variables:
- `VAULT_CERT_PATH`, `VAULT_KEY_PATH` - TLS certificate and private key paths
- `VAULT_CLIENT_SECRET`, `VAULT_DISCOVERY_PATH` - OIDC authentication configuration
- `VAULT_EXE` - Path to vault CLI executable
- `NS` - Gateway namespace for resource tagging

### 2. Template Configuration (`gw-ssl-vault.yaml`)

This is a Kong Gateway configuration template containing:

- **Certificate Configuration**: TLS certificates with vault path references
- **Service Definition**: Upstream service configuration with environment variables
- **Route Configuration**: Request routing rules with custom domain support
- **OIDC Plugin**: Single sign-on authentication using Common SSO

The template uses two types of placeholders:
- Vault paths (e.g., `aebbdd-nonprod/gateway/test/cert`) - Resolved to actual secrets
- Environment variables (e.g., `$NS`) - Substituted with values from `.env`

### 3. Injection Process (`script.py`)

The Python script performs the following operations:

1. **Load Configuration**: Reads `.env` file and template YAML
2. **Secret Resolution**: Fetches secrets from Vault using the CLI
3. **Environment Substitution**: Replaces environment variable references
4. **Output Generation**: Creates deployment-ready configuration file

## Usage

1. **Configure Environment**: Update `.env` with your vault paths and settings
1. **Prepare Template**: Ensure `gw-ssl-vault.yaml` contains correct vault references
1. **Authenticate to Vault**: Login to vault CLI before running the script
1. **set input/output**: Modify the input_file/output_file variables of the script (optional)
1. **Run Script**: Execute the Python script to generate resolved configuration
   ```bash
   python script.py
   ```
1. **Deploy Configuration**: Use GWA CLI to deploy the resolved configuration
   ```bash
   gwa config set gateway gw-0b6a6

   gwa apply -i kong-config-resolved.yaml
   # or for custom domains with TLS
   gwa pg kong-config-resolved.yaml
   ```

## Output

The script generates `kong-config-resolved.yaml` with all vault secrets and environment variables resolved to their actual values, ready for deployment to the API Gateway.

# Config File 

While the config is fairly standard there are some important details that should be mentioned. To get started review the [APS Documentation](https://developer.gov.bc.ca/docs/default/component/aps-infra-platform-docs/tutorials/quick-start/)

## Authentication
Authentication is handled via `oidc` plugin which is configured with a Common Single Sign on client secret in vault 

## Custom Domain

As this project utilizes a custom domain, the resources must be split into two seperate configuration files and the syntax differs for the certificates/services. Described [here](https://developer.gov.bc.ca/docs/default/component/aps-infra-platform-docs/how-to/custom-domain/)

## Misc

1. services.routes.preserve_host must be true when using a custom domain. Otherwise it will route to the openshift service host.
1. Contact the APS team to set up DNS. 
1. Note you may need differing tags for different branches
1. NOTE: the certificates MUST be a single line in the gateway. Depending on settings you may have to manually remove the line break:
ex:
```txt
# generated by script
somegatewayk
ey
# manually correct to
somegatewaykey
```


# network policy 
```yaml
kind: NetworkPolicy
apiVersion: networking.k8s.io/v1
metadata:
  name: allow-traffic-from-gateway-to-service
  namespace: aebbdd-dev
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/instance: isd-wiki
      app.kubernetes.io/name: isd-wiki
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              environment: dev
              name: 264e6f
    - from:
        - namespaceSelector:
            matchLabels:
              environment: test
              name: 264e6f
    - from:
        - namespaceSelector:
            matchLabels:
              environment: prod
              name: 264e6f
  policyTypes:
    - Ingress
```


## Future Work:
1. Rate limiting
1. Logging