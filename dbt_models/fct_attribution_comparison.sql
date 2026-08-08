-- Brings every attribution model's output together into one table so channel
-- credit can be compared side by side. Each model's output is loaded into its
-- own staging table upstream (first_touch, last_touch, linear, time_decay,
-- position_based, markov), this model just unions and normalizes them for
-- comparison.

with first_touch as (
    select channel, credit, 'first_touch' as model
    from {{ ref('stg_first_touch_credit') }}
),

last_touch as (
    select channel, credit, 'last_touch' as model
    from {{ ref('stg_last_touch_credit') }}
),

linear as (
    select channel, credit, 'linear' as model
    from {{ ref('stg_linear_credit') }}
),

time_decay as (
    select channel, credit, 'time_decay' as model
    from {{ ref('stg_time_decay_credit') }}
),

position_based as (
    select channel, credit, 'position_based' as model
    from {{ ref('stg_position_based_credit') }}
),

markov as (
    select channel, credit, 'markov_removal_effect' as model
    from {{ ref('stg_markov_credit') }}
),

unioned as (
    select * from first_touch
    union all select * from last_touch
    union all select * from linear
    union all select * from time_decay
    union all select * from position_based
    union all select * from markov
),

pivoted as (
    select
        channel,
        max(case when model = 'first_touch' then credit end) as first_touch_credit,
        max(case when model = 'last_touch' then credit end) as last_touch_credit,
        max(case when model = 'linear' then credit end) as linear_credit,
        max(case when model = 'time_decay' then credit end) as time_decay_credit,
        max(case when model = 'position_based' then credit end) as position_based_credit,
        max(case when model = 'markov_removal_effect' then credit end) as markov_credit
    from unioned
    group by channel
)

select
    *,
    -- Flags channels where the Markov model disagrees substantially with the
    -- average of the rule-based models, the signal worth investigating first
    abs(
        markov_credit - (
            coalesce(first_touch_credit, 0) + coalesce(last_touch_credit, 0) +
            coalesce(linear_credit, 0) + coalesce(time_decay_credit, 0) +
            coalesce(position_based_credit, 0)
        ) / 5
    ) as markov_vs_rule_based_divergence

from pivoted
order by markov_vs_rule_based_divergence desc
