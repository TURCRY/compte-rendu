# Décision: pas de response_format OpenAI en passe 1

Date: 2026-05-24

## Décision

La passe 1 du pipeline compte-rendu n'utilise pas `response_format` / `json_schema` OpenAI.

La piste structured output OpenAI est écartée pour la passe 1. Elle pourra être réévaluée seulement pour les passes 2 et suivantes, où les sorties ne portent pas l'enveloppe déterministe issue de l'ASR.

## Raison

La passe 1 doit rester robuste même si le LLM renvoie un JSON imparfait. La source de vérité est le CSV ASR, pas le LLM.

Le pipeline doit donc conserver systématiquement:

- les timecodes déterministes;
- les bornes de lignes ASR;
- le texte source;
- l'enveloppe segment;
- les segments, même si l'analyse LLM est invalide.

## Stratégie retenue

La passe 1 repose sur:

- prompt JSON strict;
- extraction JSON locale;
- réparation locale bornée;
- validation locale via `structured_output_utils.py`;
- conversion éventuelle vers le format interne historique;
- fallback local si la validation échoue.

Le LLM ne produit qu'un enrichissement. Il ne produit jamais les timecodes de référence ni l'enveloppe déterministe.

## Garde-fou

Toute réintroduction de `response_format` OpenAI pour `annoter_segments_remote` ou la passe 1 doit être considérée comme une modification d'architecture et être discutée explicitement avant relance A60.
