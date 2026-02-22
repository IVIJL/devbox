# Devbox TODO

## Testy po commitu (port broadcast + traefik filter + auto-apply)

- [ ] `devbox ls` — nezobrazuje `devbox-traefik`
- [ ] `devbox port 8080` se dvěma běžícími devboxy → route na oba, vypíše URL obou
- [ ] Spustit třetí devbox → automaticky dostane routy pro všechny default porty
- [ ] `devbox port 4000` → přidá port do `~/.devbox/default-ports.conf` a nastaví route na všechny běžící kontejnery
- [ ] `devbox ports` → zobrazí kompletní přehled, URL ve formátu `<port>.<projekt>.127.0.0.1.traefik.me` (bez `devbox-` prefixu)
- [ ] `devbox stop projekt-a` → smaže YAML configy pro projekt-a
- [ ] `devbox stop` posledního kontejneru → zastaví i traefik automaticky
- [ ] `devbox stop` → "Zastavit všechny" → zastaví kontejnery + traefik
- [ ] Restart (stop all + start nový) → porty se obnoví z `default-ports.conf`
- [ ] Ověřit že URL reálně fungují (curl na `http://8080.projekt.127.0.0.1.traefik.me`)

## Další úkoly

### Perzistence Docker volumes v DinD
- [ ] Zjistit kam DinD ukládá svá data (volumes, images, containers)
- [ ] Navrhnout named volume nebo bind mount pro DinD data storage, aby data (DB, volumes) přežila `devbox stop`
- [ ] Ověřit že compose projekty s DB (postgres, mysql, redis) přežijí restart devboxu
- [ ] Rozhodnout jestli mountovat compose soubory z host projektu nebo nechat uvnitř workspace

### Bezpečné ukončení DinD při stop/reboot
- [ ] Zjistit co se stane při `devbox stop` — dostane DinD proces SIGTERM? Ukončí se vnitřní kontejnery čistě?
- [ ] Zjistit co se stane při reboot systému bez `devbox stop` — poškodí se DB v DinD?
- [ ] Zvážit pre-stop hook: před zastavením devboxu zavolat `docker stop` na vnitřní kontejnery (graceful shutdown)
- [ ] Ověřit jestli rootless dockerd uvnitř devboxu reaguje na SIGTERM správně
- [ ] Pokud ne, přidat wrapper/trap do entrypointu který při SIGTERM nejdřív zastaví vnitřní kontejnery

### Compose soubory — mount strategie
- [ ] Rozhodnout: mount compose soubory z host projektu (bind mount `/workspace/docker-compose.yml`) vs. kopírovat dovnitř
- [ ] Aktuálně `/workspace` je bind mount → compose soubory jsou automaticky dostupné
- [ ] Ověřit že `docker compose up` uvnitř devboxu funguje s DinD a volumes přežijí restart
