# CI (Continuous Integration)

Este documento explica el workflow de CI de este repositorio y cómo interpretarlo.

## ¿Qué hace el CI aquí?
Cada vez que haces **push** o **pull request**, GitHub ejecuta automáticamente el pipeline definido en `.github/workflows/ci.yml`.  
El objetivo es detectar errores antes de mergear cambios.

## Checks que ejecuta
- **forge test**: corre toda la suite de tests (unit tests, invariants, PoCs).
- **forge fmt --check**: valida que el código esté formateado según Foundry.
- **forge coverage**: genera cobertura de tests.
- **Slither**: análisis estático para detectar patrones de vulnerabilidad.

## ¿Qué significa si falla?
- **Tests fallan** → hay regresiones o cambios que rompen la lógica esperada.
- **Fmt check falla** → hay archivos Solidity sin formatear.
- **Coverage falla** → indicador de que hay problemas en la ejecución de cobertura.
- **Slither falla** → posibles issues detectados (hay que revisar el report).

## ¿Cómo lo uso en mi flujo?
1. Creo una rama nueva con cambios.
2. Hago push.
3. GitHub ejecuta el CI.
4. Si todo pasa, se puede hacer merge con confianza.

## Comandos locales equivalentes
```bash
forge test
forge fmt --check
forge coverage
```

## Notas
- Slither puede generar avisos informativos; conviene revisar el output y decidir si son falsos positivos o riesgos reales.
- Para cambios grandes, es buena práctica correr los comandos localmente antes de push.
