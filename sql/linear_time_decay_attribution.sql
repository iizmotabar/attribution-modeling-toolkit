-- Linear and time decay attribution, built on the same journey_paths structure
-- as first_last_touch_attribution.sql. Linear splits credit evenly across every
-- touchpoint, time decay weights touchpoints closer to conversion more heavily.

with journey_paths as (
  -- Same structure as in first_last_touch_attribution.sql
  select
    user_pseudo_id,
    conversion_value,
    conversion_ts,
    touchpoints
  from `project.marts.journey_paths`  -- materialized from the base query
),

linear_credit as (
  select
    user_pseudo_id,
    t.channel,
    conversion_value / array_length(touchpoints) as credit
  from journey_paths,
  unnest(touchpoints) as t
),

time_decay_credit as (
  select
    jp.user_pseudo_id,
    t.channel,
    -- half-life of 7 days: touchpoints closer to conversion get exponentially more credit
    conversion_value * pow(0.5, timestamp_diff(jp.conversion_ts, t.session_start, hour) / (7 * 24.0))
      / sum(pow(0.5, timestamp_diff(jp.conversion_ts, t2.session_start, hour) / (7 * 24.0)))
        over (partition by jp.user_pseudo_id) as credit
  from journey_paths jp,
  unnest(touchpoints) as t
  cross join unnest(jp.touchpoints) as t2
)

-- Channel level linear credit
select channel, sum(credit) as linear_credit
from linear_credit
group by channel

union all

-- Channel level time decay credit (kept in the same output for easy comparison,
-- distinguish via a model label if querying both together)
select channel, sum(credit) as time_decay_credit
from time_decay_credit
group by channel;
