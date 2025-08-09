# Generated Files Directory

⚠️  **DO NOT EDIT** - All files in this directory are auto-generated from `config/services.yaml`

## Directory Structure

```
generated/
├── README.md              # This file
├── deployments/           # Deployment configurations
│   ├── docker-compose.yaml  # Docker Compose file
│   └── swarm-stack.yaml     # Docker Swarm stack
├── nginx/                 # Nginx configurations
│   └── templates/         # Generated nginx templates
├── config/                # Configuration files
│   ├── domains.env        # Domain environment variables
│   └── enabled-services.list # Enabled services (backward compatibility)
└── .gitignore             # Git ignore rules
```

## Regeneration

To regenerate all files:
```bash
./selfhosted.sh service generate
```

## Files Generated

- **Generated on**: Sat Aug  9 03:21:55 PM EDT 2025
- **Source**: config/services.yaml
- **Generator**: scripts/service_generator.sh

---
*This directory structure follows modern DevOps practices for clear separation between source configuration and generated artifacts.*
