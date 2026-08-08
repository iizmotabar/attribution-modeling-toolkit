"""
Computes the Markov chain removal effect attribution model. Unlike the
rule-based models in sql/, this measures each channel's actual marginal
contribution: how much overall conversion probability drops when a channel
is removed from every path it appeared in.

Reads journey paths from BigQuery (same structure produced by the base query
in first_last_touch_attribution.sql) and writes channel-level credit back.
"""

import logging
from collections import defaultdict
from itertools import product

import numpy as np
from google.cloud import bigquery

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("markov_chain_attribution")

START_STATE = "(start)"
CONVERSION_STATE = "(conversion)"
NULL_STATE = "(null)"


def fetch_journey_paths(bq_client: bigquery.Client) -> list[dict]:
    """Pulls journey paths with a converted/not-converted flag for each user."""
    query = """
        select
          user_pseudo_id,
          array_agg(channel order by session_start) as path,
          max(converted) as converted
        from `project.marts.journey_paths_with_outcome`
        group by user_pseudo_id
    """
    return [dict(row) for row in bq_client.query(query).result()]


def build_transition_matrix(paths: list[dict]) -> dict[str, dict[str, float]]:
    """Builds channel-to-channel transition probabilities including start/conversion/null states."""
    transitions = defaultdict(lambda: defaultdict(int))

    for record in paths:
        path = [START_STATE] + record["path"]
        path.append(CONVERSION_STATE if record["converted"] else NULL_STATE)

        for i in range(len(path) - 1):
            transitions[path[i]][path[i + 1]] += 1

    matrix = {}
    for state, next_states in transitions.items():
        total = sum(next_states.values())
        matrix[state] = {next_state: count / total for next_state, count in next_states.items()}

    return matrix


def total_conversion_probability(matrix: dict[str, dict[str, float]], excluded_channel: str = None) -> float:
    """
    Computes the probability of reaching CONVERSION_STATE from START_STATE,
    optionally with a channel removed from the graph (its transitions rerouted
    to NULL_STATE, simulating that channel never existing in any path).
    """
    states = list(matrix.keys())
    if excluded_channel:
        states = [s for s in states if s != excluded_channel]

    # Simple absorbing Markov chain solve via iterative simulation
    prob = defaultdict(float)
    prob[START_STATE] = 1.0

    for _ in range(50):  # enough iterations to converge for typical path lengths
        new_prob = defaultdict(float)
        for state in states:
            if state in (CONVERSION_STATE, NULL_STATE):
                new_prob[state] += prob[state]
                continue
            for next_state, p in matrix.get(state, {}).items():
                target = NULL_STATE if next_state == excluded_channel else next_state
                new_prob[target] += prob[state] * p
        prob = new_prob

    return prob[CONVERSION_STATE]


def compute_removal_effects(paths: list[dict]) -> dict[str, float]:
    """Computes each channel's removal effect: the drop in conversion probability when removed."""
    matrix = build_transition_matrix(paths)
    baseline = total_conversion_probability(matrix)

    channels = {channel for record in paths for channel in record["path"]}
    removal_effects = {}

    for channel in channels:
        with_removal = total_conversion_probability(matrix, excluded_channel=channel)
        removal_effects[channel] = max(baseline - with_removal, 0)

    total_effect = sum(removal_effects.values())
    return {channel: effect / total_effect for channel, effect in removal_effects.items()} if total_effect else {}


def main() -> None:
    bq_client = bigquery.Client()
    paths = fetch_journey_paths(bq_client)

    logger.info(f"Loaded {len(paths)} journey paths")

    normalized_credit = compute_removal_effects(paths)

    for channel, credit_share in sorted(normalized_credit.items(), key=lambda x: -x[1]):
        logger.info(f"{channel}: {credit_share:.1%} of total conversion credit")


if __name__ == "__main__":
    main()
