# Especificação: Bolão Copa do Mundo 2026 — Migração para App Dinâmico

## Contexto
Tenho um site estático de bolão (HTML/JS puro, hospedado no GitHub Pages) com 38 participantes, times, fotos, e um sistema de pontuação já funcionando. O arquivo atual é `index.html` e contém três estruturas de dados centrais:

- `const GAMES = [...]` — lista de jogos com `id`, `t1`, `t2` (times), `s1`, `s2` (placar real), `played` (bool), `h` (data/hora), `fase`.
- `const P = {...}` — objeto de participantes, cada um com `id`, `name`, `bets` (um mapa `{ jogoId: {g1, g2} }` com o palpite de cada jogo).
- `const PH = {...}` — fotos dos participantes em base64.
- Função de pontuação já implementada em JS:
```js
function pts(g1,g2,r1,r2){
  if([g1,g2,r1,r2].some(x=>x==null))return null;
  const br=g1>g2?1:g1<g2?-1:0, rr=r1>r2?1:r1<r2?-1:0;
  if(g1===r1&&g2===r2)return 18;
  if(br===rr)return(g1===r1||g2===r2)?12:9;
  return(g1===r1||g2===r2)?3:0;
}
```
(18 = placar exato, 12 = vencedor + 1 placar parcial certo, 9 = vencedor certo, 3 = perdeu vencedor mas acertou 1 placar parcial, 0 = errou tudo)

Desempate: maior nº de 18pts → maior nº de 12pts → maior nº de 9pts → maior nº de 3pts.

## Objetivo
Migrar de site estático para um app com backend, mantendo toda a lógica de pontuação e visual atual, adicionando:

### 1. Painel administrativo (só eu, Harvey)
- Login protegido por senha (só eu tenho acesso).
- Tela para inserir/editar o placar real de cada jogo (`s1`, `s2`, `played`).
- Ao salvar um resultado, o ranking de TODOS os participantes recalcula automaticamente e é refletido na tela pública imediatamente (sem precisar dar deploy ou tocar em código).
- Tela para eu ver todos os palpites de todos os participantes (visão de admin, sem restrição).
- Tela para eu definir o **prazo (data/hora) de cada jogo ou de cada fase**, após o qual os palpites daquele jogo/fase ficam travados para edição pelos participantes.

### 2. Área do participante (38 pessoas)
- Login simples: nome de usuário + senha (posso gerar senhas simples e distribuir manualmente, ex: primeiro nome + últimos 4 dígitos de telefone, ou similar — sugerir uma abordagem prática).
- Cada participante só vê e edita os **próprios** palpites.
- Participante NÃO pode ver os palpites de ninguém mais até o prazo daquele jogo expirar.
- Após o prazo expirar, os palpites daquele jogo viram travados (read-only) para esse participante — o admin ainda pode editar se precisar corrigir erro de digitação.
- Depois que TODOS os prazos de uma fase expiram, os palpites de todo mundo ficam visíveis publicamente (mantendo a experiência atual do site, onde todo mundo vê todo mundo).

### 3. Classificação (ranking)
- Pública, sem login — qualquer um pode ver.
- Recalcula automaticamente sempre que o admin insere um resultado novo (sem intervenção manual, sem re-deploy).
- Mantém a lógica de pontuação e desempate exatamente como está hoje.
- **Sem placar ao vivo em tempo real durante a partida** — o placar só atualiza quando o admin insere o resultado final (ou parcial, se quiser lançar no intervalo). Isso é intencional, para evitar custo de API de dados esportivos.

### 4. Não deve perder
- Fotos dos participantes.
- Visual/paleta de cores atual.
- Abas existentes: Prêmio Bidu (ranking geral), Prêmio Maurício Carvalho, Jogos, Por Jogo, Por Participante.
- Histórico completo de todos os jogos e palpites já inseridos até agora (dado de produção real, não pode ser perdido na migração).

## Stack sugerida
- **Frontend:** manter HTML/CSS/JS simples (ou migrar para um framework leve como Next.js/Vite, à critério do Claude Code — o importante é simplicidade de manutenção, já que sou médico e não programador).
- **Backend/banco de dados/autenticação:** Supabase (free tier). Preciso criar a conta em supabase.com antes de começar e ter a URL do projeto + chave de API (anon key) em mãos.
- **Hospedagem:** Vercel ou Netlify (free tier), com deploy automático a partir do meu repositório GitHub existente (`bolaodacopa2026/Bolaocopa2026`).

## Dados de partida
Vou fornecer o `index.html` atual como fonte de verdade dos dados (jogos, participantes, palpites, fotos, pontuação) para popular o banco de dados na migração inicial.

## Perguntas que o Claude Code pode me fazer no início
- Prefiro manter o layout visual atual ou aceito sugestões de redesign?
- Quero notificação por e-mail/WhatsApp quando o prazo de um jogo está perto de vencer? (fora de escopo por padrão, mas posso querer no futuro)
- Quero poder adicionar jogos novos (ex: rodadas futuras da Copa) direto pelo painel admin, sem precisar programar?

## Passo a passo esperado do Claude Code
1. Ler e entender o `index.html` atual (estrutura de dados e lógica de pontuação).
2. Propor esquema de banco de dados no Supabase (tabelas: `participants`, `games`, `bets`, `admin_settings` ou similar).
3. Migrar os dados existentes para o banco (script de importação a partir do `index.html`).
4. Construir autenticação (admin + 38 participantes).
5. Construir painel admin (inserir resultado, editar prazos, ver todos os palpites).
6. Construir área do participante (inserir/editar próprios palpites, respeitando prazo).
7. Construir página pública de ranking (recalculo automático).
8. Testar fluxo completo antes do deploy.
9. Fazer deploy e me entregar a URL final + instruções de como usar o painel admin no dia a dia.
