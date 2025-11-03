import yaml
import subprocess
import json
import re
import os
from dotenv import load_dotenv

# Load environment variables from .env file
load_dotenv()

# Get the VAULT_EXE path from environment variables
VAULT_EXE = os.getenv("VAULT_EXE")

if not VAULT_EXE:
    print("[ERROR] VAULT_EXE environment variable not set!")
    exit(1)


# Regex to match vault paths in the form "path/to/secret/key"
VAULT_PATH_PATTERN = re.compile(r"^(?P<path>[\w\-\/]+)/(?P<key>[\w\-]+)$")


def get_vault_secret(vault_path, secret_key):
    """
    Fetches a secret from Vault KV v2 engine.
    """
    try:
        result = subprocess.run(
            [VAULT_EXE, "kv", "get", "-format=json", vault_path],
            capture_output=True,
            check=True,
            text=True
        )
        data = json.loads(result.stdout)
        secrets_map = data.get("data", {}).get("data", {})
        return secrets_map.get(secret_key)
    except subprocess.CalledProcessError as e:
        print(f"[ERROR] Vault CLI command failed: {e.stderr.strip()}")
    except Exception as e:
        print(f"[ERROR] Unexpected error fetching secret '{vault_path}/{secret_key}': {e}")
    return None

def format_pem_secret(secret: str) -> str:
    # Remove actual newlines and encode as '\n'
    return secret.strip().replace('\r\n', '\n').replace('\n', '\\n')

def cast_env_value(value: str):
    """Cast string env values to proper types"""
    if value.lower() == 'true':
        return True
    if value.lower() == 'false':
        return False
    try:
        return int(value)
    except ValueError:
        pass
    return value

def resolve_secrets(data):
    if isinstance(data, dict):
        return {k: resolve_secrets(v) for k, v in data.items()}
    elif isinstance(data, list):
        return [resolve_secrets(item) for item in data]
    elif isinstance(data, str):
        # Vault path pattern
        match = VAULT_PATH_PATTERN.match(data)
        if match:
            vault_path = match.group("path")
            secret_key = match.group("key")
            secret = get_vault_secret(vault_path, secret_key)
            if secret is not None:
                if any(tag in secret for tag in ["PRIVATE KEY", "CERTIFICATE"]):
                    return format_pem_secret(secret)
                return secret
            return data  # fallback to original

        # Environment variable substitution
        if data.startswith('$'):
            env_var = data[1:]
            value = os.getenv(env_var, data)
            return cast_env_value(value)

        return data
    else:
        return data

def main():
    input_file = "./gateway/automate/gw-ssl-vault.yaml"
    output_file = "kong-config-resolved.yaml"

    print(f"[INFO] Loading config from '{input_file}'...")
    with open(input_file, "r") as f:
        config = yaml.safe_load(f)

    print("[INFO] Resolving Vault secrets and environment variables...")
    resolved_config = resolve_secrets(config)
    print(f"[INFO] Writing resolved config to '{output_file}'...")
    with open(output_file, "w") as f:
        yaml.dump(
            resolved_config,
            f,
            default_flow_style=False,
            allow_unicode=True,
            width=float("inf"),  # prevent line wrapping
        )

    print("[INFO] Done.")

if __name__ == "__main__":
    main()
