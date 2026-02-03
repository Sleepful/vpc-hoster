# Tradeoffs of PGL for development:
# - Very powerful but also very heavy, it tends to slow me down.
# - What makes it slow?
#   - Figuring out GraphQl topics
#   - Figuring out PGL topics (when special configurations are needed)
#   - Handling migrations (these are separate from app deployments)
#   - A lot of nuance when it comes to auth, requires SQL for auth permissions and PG users
#   - PG configurations start to mix between declarative (nix) and imperative (migrations)
