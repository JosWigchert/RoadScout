package main

import "sort"

// defaultDetourOptions are the extra-travel-time budgets advertised for
// experimental objectives. Fastest has no detour budget.
var defaultDetourOptions = []int{15, 30, 50, 85, 100}

type RoutingOption struct {
	ID            string `json:"id"`
	Title         string `json:"title"`
	Experimental  bool   `json:"experimental"`
	DetourOptions []int  `json:"detourOptions"`
}

type routingCatalog interface {
	RoutingOptions() []RoutingOption
}

func fastestOption() RoutingOption {
	return RoutingOption{ID: "fastest", Title: "Fastest", DetourOptions: []int{}}
}

func (v *Valhalla) RoutingOptions() []RoutingOption { return []RoutingOption{fastestOption()} }

func (r *experimentalRouter) RoutingOptions() []RoutingOption {
	return []RoutingOption{
		fastestOption(),
		{ID: "scenic", Title: "Scenic", Experimental: true, DetourOptions: append([]int(nil), defaultDetourOptions...)},
		{ID: "more_corners", Title: "More Corners", Experimental: true, DetourOptions: append([]int(nil), defaultDetourOptions...)},
	}
}

func routingOptions(provider RoutingProvider) []RoutingOption {
	if catalog, ok := provider.(routingCatalog); ok {
		if options := catalog.RoutingOptions(); len(options) > 0 {
			return options
		}
	}
	return []RoutingOption{fastestOption()}
}

func routingObjectives(provider RoutingProvider) []string {
	options := routingOptions(provider)
	ids := make([]string, 0, len(options))
	for _, option := range options {
		ids = append(ids, option.ID)
	}
	return ids
}

func catalogDetourOptions(options []RoutingOption) []int {
	seen := map[int]bool{}
	result := []int{}
	for _, option := range options {
		for _, value := range option.DetourOptions {
			if !seen[value] {
				seen[value] = true
				result = append(result, value)
			}
		}
	}
	sort.Ints(result)
	return result
}
