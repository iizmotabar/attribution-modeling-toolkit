-- Builds the customer journey path per converting user, then derives first touch
-- and last touch attribution from it. This is the base query every other model
-- in this toolkit reads from, so the journey definition stays consistent across
-- all six models.

with sessions as (
  select
    user_pseudo_id,
    (select value.string_value from unnest(event_params) where key = 'source') as channel,
    timestamp_micros(min(event_timestamp)) as session_start
  from `project.analytics_XXXXXXXX.events_*`
  where event_name = 'session_start'
  group by user_pseudo_id, channel
),

conversions as (
  select
    user_pseudo_id,
    timestamp_micros(event_timestamp) as conversion_ts,
    (select value.double_value from unnest(event_params) where key = 'value') as conversion_value
  from `project.analytics_XXXXXXXX.events_*`
  where event_name in ('purchase', 'generate_lead')
),

journey_paths as (
  select
    c.user_pseudo_id,
    c.conversion_ts,
    c.conversion_value,
    array_agg(
      struct(s.channel, s.session_start)
      order by s.session_start
    ) as touchpoints
  from conversions c
  join sessions s
    on c.user_pseudo_id = s.user_pseudo_id
    and s.session_start <= c.conversion_ts
  group by c.user_pseudo_id, c.conversion_ts, c.conversion_value
)

select
  user_pseudo_id,
  conversion_value,
  touchpoints[offset(0)].channel as first_touch_channel,
  touchpoints[offset(array_length(touchpoints) - 1)].channel as last_touch_channel,
  array_length(touchpoints) as total_touchpoints
from journey_paths;

-- Aggregate to channel level credit:
-- First touch model: 100% of conversion_value goes to first_touch_channel
-- Last touch model: 100% of conversion_value goes to last_touch_channel
-- Both are simple group-by-and-sum on top of the query above, e.g.:
--
-- select first_touch_channel as channel, sum(conversion_value) as first_touch_credit
-- from journey_paths_output
-- group by first_touch_channel
