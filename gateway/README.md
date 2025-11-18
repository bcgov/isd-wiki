# BC Government APS Gateway Services 

The BC Government API Program Services (APS) provide a secure, standardized platform for managing and routing APIs across government systems. Built on APISIX and deployed in OpenShift, the gateway enforces consistent authentication, authorization, encryption, and logging while simplifying API exposure and integration. Developers use tools like gwa and deck to register and manage APIs declaratively, ensuring compliance with government security and governance standards.

## Getting started

The APS team provides a [quick start](https://developer.gov.bc.ca/docs/default/component/aps-infra-platform-docs/tutorials/quick-start/) guide that does a good job of helping get started. Including CLI commands to template a basic gateway. In this document we will link/explain common conceps and FAQs 

### Custom domain

Steps to configure a custom domain are [here](https://developer.gov.bc.ca/docs/default/component/aps-infra-platform-docs/how-to/custom-domain/)

### Plugins

Plugins enable easy extension of the gateways capabilities, some commonly used plugins are [here](https://developer.gov.bc.ca/docs/default/component/aps-infra-platform-docs/concepts/plugins/)

#### Authentication

NOTE for authentication with a custom domain, routes.preserve_host MUST be true or it will forward to the service

## GWA CLI
Some commonly used gwa cli commands
```bash
# set gateway
gwa config set gateway <gateway-name-or-id>

# apply (deploy) a gateway
gwa apply -i gw-config.yaml

# apply (deploy) a gateway with a custom domain
gwa pg gw-config.yaml
```

### Version Control
Gateway version control is currently handled via template script with vault injection, see ./gateway/README.md

## Deck

deck (Declarative Configuration) is a command-line tool originally designed for Kong gateways that lets you manage gateway configuration (routes, services, and plugins) as code. It’s typically used to export, diff, and sync configurations in YAML format, but for BC Gov APS setups that already use Git + gwa, it’s optional since the Git-based workflow already provides declarative control and versioning of gateway configs.
[Official documentation](https://docs.konghq.com/deck/latest/)

# FAQ

## Remove a gateway
Removing a gateway can be done via the APS portal or with gwa gateway destroy. 

## Disabling a gateway
While there is no 'built in' way to disable a gateway. In practice this can be done by commenting out the routes.

## Namespaces - dev/test/prod
To use the same gateway across different namespaces. You can modify the `tag` before deploying: e.g:   tags: [ns.gw-0b6a6.prod]

## Support
The BC Government APS team has a rocketchat channel `aps-ops` for support