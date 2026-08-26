# Search strategy: full Boolean strings as executed

Generated from `annex_code/R/search_terms.R`, the single committed source of every
search term used in this review.

Every query is the Boolean intersection of three blocks (conflict AND wildlife AND
geography), restricted to publication years 2020-2024. Queries were issued one
source x one language x one geographic cell, so every retrieved record carries the
identity of the query that found it; a single merged query would have destroyed the
per-cell yield information reported in the Results.

Block lengths quoted in the manuscript (19/38/6 English, 7/4/7 French, 6/5/7 Arabic)
count committed *entries*. The English geography entry is a nested list of 6 cells
that expands to 19 literal search terms; the others are flat.

## English cell

Geography: 6 geographic cells (5 countries + 1 regional), expanding to 19 terms with adjectival forms

```
("human-wildlife conflict" OR "human wildlife conflict" OR "human-wildlife coexistence" OR "human-wildlife interaction" OR "crop raiding" OR "crop damage" OR "crop depredation" OR "livestock depredation" OR "livestock predation" OR "retaliatory killing" OR "problem animal" OR "wildlife damage" OR "depredation" OR "persecution" OR "poisoning" OR "attacks on humans" OR "bycatch" OR "by-catch" OR "incidental catch") AND ("wildlife" OR "mammal" OR "carnivore" OR "primate" OR "macaque" OR "ungulate" OR "boar" OR "jackal" OR "hyaena" OR "hyena" OR "fox" OR "mongoose" OR "porcupine" OR "raptor" OR "eagle" OR "vulture" OR "falcon" OR "stork" OR "flamingo" OR "reptile" OR "snake" OR "turtle" OR "tortoise" OR "dolphin" OR "cetacean" OR "seal" OR "shark" OR "Sus scrofa" OR "Canis aureus" OR "Canis lupaster" OR "Hyaena hyaena" OR "Macaca sylvanus" OR "Caretta caretta" OR "Monachus monachus" OR "Hystrix cristata" OR "Vulpes zerda" OR "Gazella dorcas" OR "Ammotragus lervia") AND ("Tunisia" OR "Tunisian" OR "Algeria" OR "Algerian" OR "Morocco" OR "Moroccan" OR "Libya" OR "Libyan" OR "Egypt" OR "Egyptian" OR "North Africa" OR "Northern Africa" OR "Maghreb" OR "Atlas Mountains" OR "Gulf of Gabes" OR "Gulf of Gabès" OR "Ichkeul" OR "Djurdjura" OR "Kroumirie")
```

**Conflict block (19):** human-wildlife conflict; human wildlife conflict; human-wildlife coexistence; human-wildlife interaction; crop raiding; crop damage; crop depredation; livestock depredation; livestock predation; retaliatory killing; problem animal; wildlife damage; depredation; persecution; poisoning; attacks on humans; bycatch; by-catch; incidental catch

**Wildlife block (38):** wildlife; mammal; carnivore; primate; macaque; ungulate; boar; jackal; hyaena; hyena; fox; mongoose; porcupine; raptor; eagle; vulture; falcon; stork; flamingo; reptile; snake; turtle; tortoise; dolphin; cetacean; seal; shark; Sus scrofa; Canis aureus; Canis lupaster; Hyaena hyaena; Macaca sylvanus; Caretta caretta; Monachus monachus; Hystrix cristata; Vulpes zerda; Gazella dorcas; Ammotragus lervia

**Geography terms (19 literal):** Tunisia; Tunisian; Algeria; Algerian; Morocco; Moroccan; Libya; Libyan; Egypt; Egyptian; North Africa; Northern Africa; Maghreb; Atlas Mountains; Gulf of Gabes; Gulf of Gabès; Ichkeul; Djurdjura; Kroumirie

## French cell

Geography: 7 terms, issued as one cell

```
("conflit homme-faune" OR "conflits homme-animal" OR "dégâts de sanglier" OR "dégâts aux cultures" OR "prédation du bétail" OR "capture accidentelle" OR "prise accessoire") AND ("sanglier" OR "chacal" OR "hyène rayée" OR "macaque de Barbarie") AND ("Tunisie" OR "Algérie" OR "Maroc" OR "Libye" OR "Égypte" OR "Maghreb" OR "Afrique du Nord")
```

**Conflict block (7):** conflit homme-faune; conflits homme-animal; dégâts de sanglier; dégâts aux cultures; prédation du bétail; capture accidentelle; prise accessoire

**Wildlife block (4):** sanglier; chacal; hyène rayée; macaque de Barbarie

**Geography terms (7 literal):** Tunisie; Algérie; Maroc; Libye; Égypte; Maghreb; Afrique du Nord

## Arabic cell

Geography: 7 terms, issued as one cell

```
("الصراع بين الإنسان والحياة البرية" OR "التعارض بين الإنسان والحياة البرية" OR "تعايش الإنسان والحياة البرية" OR "أضرار المحاصيل" OR "افتراس الماشية" OR "الصيد العرضي") AND ("الحياة البرية" OR "خنزير بري" OR "ابن آوى" OR "ضبع" OR "سلحفاة بحرية") AND ("تونس" OR "الجزائر" OR "المغرب" OR "ليبيا" OR "مصر" OR "شمال أفريقيا" OR "المغرب العربي")
```

**Conflict block (6):** الصراع بين الإنسان والحياة البرية; التعارض بين الإنسان والحياة البرية; تعايش الإنسان والحياة البرية; أضرار المحاصيل; افتراس الماشية; الصيد العرضي

**Wildlife block (5):** الحياة البرية; خنزير بري; ابن آوى; ضبع; سلحفاة بحرية

**Geography terms (7 literal):** تونس; الجزائر; المغرب; ليبيا; مصر; شمال أفريقيا; المغرب العربي

## The asymmetry

English wildlife block: 38 terms. French: 4. Arabic: 5.
All 11 Latin binomials sit in the English block only, and those are the terms most
likely to bridge a francophone or arabophone paper into an English-indexed search.
No multilingual thesaurus (e.g. AGROVOC) was used to generate the non-English blocks;
they were written by hand. This asymmetry is the review's central identified
limitation and the reason zero French or Arabic records reached the analytic set.

