-- ============================================================================
-- Bolão da Copa 2026 — schema Supabase
-- Cole este arquivo inteiro no SQL Editor do Supabase (Dashboard → SQL Editor)
-- e clique em "Run". Pode ser rodado mais de uma vez sem quebrar nada.
-- ============================================================================

create extension if not exists pgcrypto;

-- ---------------------------------------------------------------------------
-- TABELAS
-- ---------------------------------------------------------------------------

create table if not exists participants (
  id           uuid primary key default gen_random_uuid(),
  legacy_id    int unique,                 -- id numérico do participante no site antigo
  user_id      uuid unique references auth.users(id) on delete cascade,
  username     text unique not null,       -- usado para login (username@bolao.local)
  name         text not null,
  photo_url    text,
  is_admin     boolean not null default false,
  created_at   timestamptz not null default now()
);

create table if not exists games (
  id                     int primary key,   -- mesmo id do site antigo (1..104)
  t1                     text not null,
  t2                     text not null,
  s1                     int,
  s2                     int,
  played                 boolean not null default false,
  fase                   text not null,
  kickoff_at             timestamptz,        -- data/hora real do jogo (null se "A definir")
  bet_deadline_override  timestamptz         -- se setado, vence o prazo da fase pra este jogo
);

create table if not exists phase_deadlines (
  fase      text primary key,
  deadline  timestamptz not null
);

create table if not exists bets (
  participant_id  uuid not null references participants(id) on delete cascade,
  game_id         int  not null references games(id) on delete cascade,
  g1              int not null,
  g2              int not null,
  updated_at      timestamptz not null default now(),
  primary key (participant_id, game_id)
);

create index if not exists bets_game_id_idx on bets(game_id);
create index if not exists games_fase_idx on games(fase);

-- ---------------------------------------------------------------------------
-- FUNÇÕES
-- ---------------------------------------------------------------------------

-- Mesma regra de pontuação do JS original (18/12/9/3/0).
create or replace function pts(g1 int, g2 int, r1 int, r2 int)
returns int
language sql immutable
as $$
  select case
    when g1 is null or g2 is null or r1 is null or r2 is null then null
    when g1 = r1 and g2 = r2 then 18
    when sign(g1 - g2) = sign(r1 - r2) then (case when g1 = r1 or g2 = r2 then 12 else 9 end)
    else (case when g1 = r1 or g2 = r2 then 3 else 0 end)
  end
$$;

-- security definer: evita recursão de RLS ao consultar participants dentro de policies.
create or replace function is_admin()
returns boolean
language sql security definer stable set search_path = public
as $$
  select coalesce((select is_admin from participants where user_id = auth.uid()), false)
$$;

create or replace function current_participant_id()
returns uuid
language sql security definer stable set search_path = public
as $$
  select id from participants where user_id = auth.uid()
$$;

-- Prazo efetivo de um jogo: override do jogo > horário do jogo > prazo da fase.
create or replace function effective_deadline(gid int)
returns timestamptz
language sql stable
as $$
  select coalesce(g.bet_deadline_override, g.kickoff_at, pd.deadline)
  from games g
  left join phase_deadlines pd on pd.fase = g.fase
  where g.id = gid
$$;

-- Só fica true quando o prazo de TODOS os jogos daquela fase já venceu
-- (implementa "todo mundo só vê os palpites de todo mundo depois que a fase inteira fecha").
create or replace function is_phase_visible(p_fase text)
returns boolean
language sql stable
as $$
  select coalesce(bool_and(now() > effective_deadline(g.id)), false)
  from games g
  where g.fase = p_fase
$$;

-- Conjunto de fases já totalmente encerradas, calculado UMA vez por consulta
-- (em vez de is_phase_visible ser recalculado linha a linha dentro da policy
-- de bets — com milhares de palpites isso estourava o tempo limite do banco).
create or replace function visible_fases()
returns table(fase text)
language sql stable
as $$
  select g.fase
  from games g
  group by g.fase
  having bool_and(now() > effective_deadline(g.id))
$$;

grant execute on function pts(int,int,int,int) to anon, authenticated;
grant execute on function effective_deadline(int) to anon, authenticated;
grant execute on function is_phase_visible(text) to anon, authenticated;
grant execute on function visible_fases() to anon, authenticated;
grant execute on function is_admin() to anon, authenticated;
grant execute on function current_participant_id() to anon, authenticated;

-- ---------------------------------------------------------------------------
-- VIEWS PÚBLICAS (rodam com privilégio do owner, ignoram RLS das tabelas base
-- de propósito: só expõem dados agregados/seguros, nunca palpites individuais
-- antes do prazo)
-- ---------------------------------------------------------------------------

create or replace view participants_public as
select id, legacy_id, name, photo_url
from participants;

create or replace view public_ranking as
select
  p.id as participant_id,
  p.name,
  p.photo_url,
  coalesce(sum(pts(b.g1,b.g2,g.s1,g.s2)) filter (where pts(b.g1,b.g2,g.s1,g.s2) is not null), 0) as tot,
  count(*) filter (where pts(b.g1,b.g2,g.s1,g.s2) = 18) as c18,
  count(*) filter (where pts(b.g1,b.g2,g.s1,g.s2) = 12) as c12,
  count(*) filter (where pts(b.g1,b.g2,g.s1,g.s2) = 9)  as c9,
  count(*) filter (where pts(b.g1,b.g2,g.s1,g.s2) = 3)  as c3,
  count(*) filter (where pts(b.g1,b.g2,g.s1,g.s2) = 0)  as c0
from participants p
left join bets b on b.participant_id = p.id
left join games g on g.id = b.game_id
group by p.id, p.name, p.photo_url;

-- ---------------------------------------------------------------------------
-- ROW LEVEL SECURITY
-- ---------------------------------------------------------------------------

alter table participants enable row level security;
alter table games enable row level security;
alter table phase_deadlines enable row level security;
alter table bets enable row level security;

-- participants: tabela base fica travada (dono ou admin). Uso público passa
-- pela view participants_public acima.
drop policy if exists participants_select on participants;
create policy participants_select on participants
  for select using (user_id = auth.uid() or is_admin());

-- games: leitura pública, escrita só admin.
drop policy if exists games_select on games;
create policy games_select on games for select using (true);

drop policy if exists games_insert on games;
create policy games_insert on games for insert with check (is_admin());

drop policy if exists games_update on games;
create policy games_update on games for update using (is_admin()) with check (is_admin());

-- phase_deadlines: leitura pública, escrita só admin.
drop policy if exists phase_deadlines_select on phase_deadlines;
create policy phase_deadlines_select on phase_deadlines for select using (true);

drop policy if exists phase_deadlines_insert on phase_deadlines;
create policy phase_deadlines_insert on phase_deadlines for insert with check (is_admin());

drop policy if exists phase_deadlines_update on phase_deadlines;
create policy phase_deadlines_update on phase_deadlines for update using (is_admin()) with check (is_admin());

drop policy if exists phase_deadlines_delete on phase_deadlines;
create policy phase_deadlines_delete on phase_deadlines for delete using (is_admin());

-- bets: dono sempre vê/edita o próprio (edita só antes do prazo); admin vê/edita tudo;
-- qualquer um (mesmo anônimo) vê palpites de fases já totalmente encerradas.
drop policy if exists bets_select on bets;
create policy bets_select on bets for select using (
  participant_id = current_participant_id()
  or is_admin()
  or (select fase from games where id = bets.game_id) in (select fase from visible_fases())
);

drop policy if exists bets_insert on bets;
create policy bets_insert on bets for insert with check (
  (participant_id = current_participant_id() and now() < effective_deadline(game_id))
  or is_admin()
);

drop policy if exists bets_update on bets;
create policy bets_update on bets for update
  using (participant_id = current_participant_id() or is_admin())
  with check (
    (participant_id = current_participant_id() and now() < effective_deadline(game_id))
    or is_admin()
  );

create or replace function set_updated_at() returns trigger language plpgsql as $$
begin new.updated_at = now(); return new; end
$$;

drop trigger if exists bets_set_updated_at on bets;
create trigger bets_set_updated_at before update on bets
for each row execute function set_updated_at();

-- ---------------------------------------------------------------------------
-- GRANTS (privilégio de tabela; RLS acima controla o acesso por linha)
-- ---------------------------------------------------------------------------

grant usage on schema public to anon, authenticated;

grant select on participants_public to anon, authenticated;
grant select on public_ranking to anon, authenticated;

grant select on games to anon, authenticated;
grant insert, update on games to authenticated;

grant select on phase_deadlines to anon, authenticated;
grant insert, update, delete on phase_deadlines to authenticated;

grant select on participants to anon, authenticated;

grant select, insert, update on bets to authenticated;

-- ---------------------------------------------------------------------------
-- STORAGE (fotos dos participantes)
-- ---------------------------------------------------------------------------

insert into storage.buckets (id, name, public)
values ('photos', 'photos', true)
on conflict (id) do nothing;

drop policy if exists "Public read photos" on storage.objects;
create policy "Public read photos" on storage.objects
  for select using (bucket_id = 'photos');
