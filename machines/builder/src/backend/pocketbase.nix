
{ pkgs, modulesPath, ... }:
{
  environment.systemPackages = [
    pkgs.pocketbase
  ];
}

/*

Benefits of PB for development:
- No need to run migrations
- Instant OAuth and similar
- Zero worries about backend
- Independent storages (multiple dbs use separate db instances, no mix of users and schemas)
Tradeoffs of PB:
- Does not scale horizontally (Not something that I have to worry about, especially not for custom personal apps)

When to use:
- Almost always use

For Backup:
- PB comes with snapshot to object storage, just configure it

For extreme scenarios:
- Use Dynamodb for data that needs 100% durability, would require adding special PB hooks
- Avoid PB if 1 hour of downtime per month sounds like too much (never have I seen this)
- In case of massive success, LiteFS experiments could be done for redundancy, or Go-Ha sqlite driver 
  - (litesql/pocketbase-ha)
  - (https://www.reddit.com/r/pocketbase/comments/1pl1h07/my_hack_attempt_at_horizontal_scaling_curious_if/)
  - (https://www.reddit.com/r/sqlite/comments/1nmfnry/comment/nflij3q/?context=3&sort=top)
- LiteStream for super frequent backup


*/
