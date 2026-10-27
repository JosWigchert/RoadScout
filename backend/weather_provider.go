package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"math"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"
)

// Provider abstraction. Only Open-Meteo is active, but the service accepts a
// list so a second (for example KNMI) adapter can be merged in later without
// changing the route sampling, recommendation or wire contract.
type weatherSample struct {
	Coordinate Point
	At         time.Time
	Meters     float64
	Index      int
}

// sampleForecast is one provider's answer for one sample. Available is false
// when the provider returned no usable value for the requested time (missing
// bucket, stale range or absent probability), in which case the recommendation
// must not assert dry.
type sampleForecast struct {
	Available          bool
	ProbabilityPercent int
	IntensityMmPerHour float64
}

type WeatherProviderInfo struct {
	ID          string `json:"id"`
	Name        string `json:"name"`
	License     string `json:"license"`
	Attribution string `json:"attribution"`
	Coverage    string `json:"coverage"`
}

type weatherProvider interface {
	Info() WeatherProviderInfo
	Forecast(ctx context.Context, samples []weatherSample) ([]sampleForecast, error)
}

// worstForecast merges the same sample from several providers. Missing coverage
// is ignored: when at least one provider covers the sample the result is
// available and uses the worse (higher) probability and intensity, matching the
// "when both cover a sample, use the worse" decision.
func worstForecast(forecasts ...sampleForecast) sampleForecast {
	merged := sampleForecast{}
	available := false
	for _, forecast := range forecasts {
		if !forecast.Available {
			continue
		}
		if !available {
			merged = forecast
			available = true
			continue
		}
		if forecast.ProbabilityPercent > merged.ProbabilityPercent {
			merged.ProbabilityPercent = forecast.ProbabilityPercent
		}
		if forecast.IntensityMmPerHour > merged.IntensityMmPerHour {
			merged.IntensityMmPerHour = forecast.IntensityMmPerHour
		}
	}
	merged.Available = available
	return merged
}

const (
	openMeteoProviderID   = "open-meteo"
	openMeteoBatchSize    = 50
	openMeteoMaxForecast  = 16
	precipitationInterval = 15 * time.Minute
	probabilityInterval   = time.Hour
)

type openMeteoProvider struct {
	BaseURL string
	Client  *http.Client
	Now     func() time.Time
}

func newOpenMeteo(base string) (*openMeteoProvider, error) {
	u, err := url.Parse(base)
	if err != nil || u.Host == "" || (u.Scheme != "http" && u.Scheme != "https") || u.User != nil || u.RawQuery != "" || u.Fragment != "" {
		return nil, fmt.Errorf("invalid OPEN_METEO_BASE_URL")
	}
	return &openMeteoProvider{BaseURL: strings.TrimRight(base, "/"), Client: &http.Client{Timeout: 10 * time.Second, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}, Now: time.Now}, nil
}

func (p *openMeteoProvider) Info() WeatherProviderInfo {
	return WeatherProviderInfo{
		ID:          openMeteoProviderID,
		Name:        "Open-Meteo",
		License:     "CC BY 4.0",
		Attribution: "Weather data by Open-Meteo.com",
		Coverage:    "Worldwide; 15-minute precipitation in the Netherlands/Central Europe",
	}
}

// Forecast fetches 15-minute precipitation and hourly probability for every
// sample, batching at most openMeteoBatchSize coordinates per upstream request.
func (p *openMeteoProvider) Forecast(ctx context.Context, samples []weatherSample) ([]sampleForecast, error) {
	result := make([]sampleForecast, len(samples))
	for start := 0; start < len(samples); start += openMeteoBatchSize {
		end := start + openMeteoBatchSize
		if end > len(samples) {
			end = len(samples)
		}
		forecasts, err := p.forecastBatch(ctx, samples[start:end])
		if err != nil {
			return nil, err
		}
		copy(result[start:end], forecasts)
	}
	return result, nil
}

type openMeteoMinutely struct {
	Time          []string   `json:"time"`
	Precipitation []*float64 `json:"precipitation"`
}
type openMeteoHourly struct {
	Time                     []string   `json:"time"`
	PrecipitationProbability []*float64 `json:"precipitation_probability"`
}
type openMeteoPayload struct {
	Minutely15 openMeteoMinutely `json:"minutely_15"`
	Hourly     openMeteoHourly   `json:"hourly"`
}

func (p *openMeteoProvider) forecastBatch(ctx context.Context, batch []weatherSample) ([]sampleForecast, error) {
	latitudes := make([]string, len(batch))
	longitudes := make([]string, len(batch))
	minAt, maxAt := batch[0].At, batch[0].At
	for i, sample := range batch {
		latitudes[i] = strconv.FormatFloat(sample.Coordinate.Latitude, 'f', 5, 64)
		longitudes[i] = strconv.FormatFloat(sample.Coordinate.Longitude, 'f', 5, 64)
		if sample.At.Before(minAt) {
			minAt = sample.At
		}
		if sample.At.After(maxAt) {
			maxAt = sample.At
		}
	}
	now := p.Now().UTC()
	days := int(math.Ceil(maxAt.UTC().Sub(now).Hours()/24)) + 1
	if days < 1 {
		days = 1
	}
	if days > openMeteoMaxForecast {
		days = openMeteoMaxForecast
	}
	query := url.Values{}
	query.Set("latitude", strings.Join(latitudes, ","))
	query.Set("longitude", strings.Join(longitudes, ","))
	query.Set("minutely_15", "precipitation")
	query.Set("hourly", "precipitation_probability")
	query.Set("timezone", "UTC")
	query.Set("forecast_days", strconv.Itoa(days))

	request, err := http.NewRequestWithContext(ctx, "GET", p.BaseURL+"?"+query.Encode(), nil)
	if err != nil {
		return nil, err
	}
	response, err := p.Client.Do(request)
	if err != nil {
		if ctx.Err() != nil {
			return nil, ctx.Err()
		}
		return nil, apiError("weather_unavailable")
	}
	defer response.Body.Close()
	body, err := io.ReadAll(io.LimitReader(response.Body, 8_000_001))
	if err != nil || len(body) > 8_000_000 {
		return nil, apiError("weather_unavailable")
	}
	if response.StatusCode != http.StatusOK {
		return nil, apiError("weather_unavailable")
	}
	payloads, err := decodeOpenMeteo(body)
	if err != nil || len(payloads) != len(batch) {
		return nil, apiError("weather_unavailable")
	}
	forecasts := make([]sampleForecast, len(batch))
	for i := range batch {
		forecasts[i] = alignForecast(payloads[i], batch[i].At)
	}
	return forecasts, nil
}

func decodeOpenMeteo(body []byte) ([]openMeteoPayload, error) {
	trimmed := bytes.TrimSpace(body)
	if len(trimmed) == 0 {
		return nil, apiError("weather_unavailable")
	}
	if trimmed[0] == '[' {
		var payloads []openMeteoPayload
		if err := json.Unmarshal(trimmed, &payloads); err != nil {
			return nil, err
		}
		return payloads, nil
	}
	var single openMeteoPayload
	if err := json.Unmarshal(trimmed, &single); err != nil {
		return nil, err
	}
	return []openMeteoPayload{single}, nil
}

// alignForecast maps an ETA to the preceding interval ending at each provider
// timestamp: precipitation covers (stamp-15min, stamp], probability (stamp-1h, stamp].
// Both are UTC. Probability is hourly,
// so it is coarser than the 15-minute intensity; that resolution difference is
// documented rather than hidden.
func alignForecast(payload openMeteoPayload, at time.Time) sampleForecast {
	at = at.UTC()
	precipitationIndex := -1
	for i, raw := range payload.Minutely15.Time {
		stamp, err := time.Parse("2006-01-02T15:04", raw)
		if err != nil {
			return sampleForecast{}
		}
		stamp = stamp.UTC()
		if at.After(stamp.Add(-precipitationInterval)) && !at.After(stamp) {
			precipitationIndex = i
			break
		}
	}
	if precipitationIndex < 0 || precipitationIndex >= len(payload.Minutely15.Precipitation) {
		return sampleForecast{}
	}
	amountValue := payload.Minutely15.Precipitation[precipitationIndex]
	if amountValue == nil || !finite(*amountValue) || *amountValue < 0 {
		return sampleForecast{}
	}
	amount := *amountValue
	probabilityIndex := -1
	for i, raw := range payload.Hourly.Time {
		stamp, err := time.Parse("2006-01-02T15:04", raw)
		if err != nil {
			return sampleForecast{}
		}
		stamp = stamp.UTC()
		if at.After(stamp.Add(-probabilityInterval)) && !at.After(stamp) {
			probabilityIndex = i
			break
		}
	}
	if probabilityIndex < 0 || probabilityIndex >= len(payload.Hourly.PrecipitationProbability) {
		return sampleForecast{}
	}
	probability := payload.Hourly.PrecipitationProbability[probabilityIndex]
	if probability == nil || !finite(*probability) || *probability < 0 {
		return sampleForecast{}
	}
	return sampleForecast{Available: true, ProbabilityPercent: int(math.Round(*probability)), IntensityMmPerHour: amount * 4}
}
